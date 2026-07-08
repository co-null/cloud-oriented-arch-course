import base64
import json
import os
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry
from google.cloud import firestore
import datetime

# ─── Ініціалізація (один раз при cold start) ───

_db = firestore.Client()

def _create_session() -> requests.Session:
    session = requests.Session()
    retry = Retry(
        total=3, backoff_factor=2,
        status_forcelist=[503],
        allowed_methods=["POST"],
        raise_on_status=False
    )
    session.mount("https://", HTTPAdapter(max_retries=retry))
    return session

_http = _create_session()

EMAIL_SENDER_URL = os.environ.get("EMAIL_SENDER_URL")
ADMIN_EMAIL      = os.environ.get("ADMIN_EMAIL")
PROJECT_ID       = os.environ.get("GCP_PROJECT")

# ─── Idempotency helpers ───
def _is_duplicate(event_id: str) -> bool:
    doc = _db.collection("processed_notifications").document(event_id).get()
    return doc.exists

def _mark_processed(event_id: str, event_type: str):
    _db.collection("processed_notifications").document(event_id).set({
        "processed_at": datetime.datetime.utcnow().isoformat(),
        "event_type":   event_type
    })

# ─── REST-виклик email-sender ───

def _call_email_sender(endpoint: str, payload: dict, event_id: str):
    """
    Викликає email-sender функцію по REST.
    Повертає True при успіху, False при клієнтській помилці,
    кидає виняток при серверній помилці (щоб Pub/Sub зробив retry).
    """
    url = f"{EMAIL_SENDER_URL}{endpoint}"

    try:
        resp = _http.post(url, json=payload, timeout=30)
    except requests.exceptions.Timeout:
        raise RuntimeError(f"email-sender timeout | event_id={event_id}")
    except requests.exceptions.ConnectionError as e:
        raise RuntimeError(f"email-sender unreachable: {e} | event_id={event_id}")

    if resp.status_code == 200:
        print(f"[INFO] Email sent | event_id={event_id}")
        return True
    elif resp.status_code == 400:
        # Клієнтська помилка — не кидаємо виняток, не робимо retry
        print(f"[ERROR] Bad request to email-sender: {resp.text[:200]} | event_id={event_id}")
        return False
    else:
        # Серверна помилка — кидаємо виняток → Pub/Sub зробить retry
        raise RuntimeError(
            f"email-sender returned {resp.status_code} | event_id={event_id}"
        )

# ─── Обробники подій ───

def _dispatch_booking_created(event: dict, event_id: str):
    payload = {
        "recipient":    event["user_id"],
        "user_name":    event.get("user_name", "Клієнт"),
        "booking_id":   event["booking_id"],
        "apartment_id": event["apartment_id"],
        "start_date":   event["start_date"],
        "end_date":     event["end_date"],
        "price":        event.get('price', '—')
    }
    _call_email_sender("/send-booking-email", payload, event_id)

def _dispatch_apartment_added(event: dict, event_id: str):
    if not ADMIN_EMAIL:
        print("[WARNING] ADMIN_EMAIL not set — skipping apartment_added notification")
        return

    payload = {
        "recipient": ADMIN_EMAIL,
        "subject":   f"🏠 Нова квартира: {event.get('address', event.get('apartment_id'))}",
        "text": (
            f"Додано нову квартиру.\n"
            f"ID: {event.get('apartment_id')}\n"
            f"Адреса: {event.get('address', 'не вказано')}\n"
            f"Ціна/день: {event.get('price', '—')} UAH"
        )
    }
    _call_email_sender("/send-email", payload, event_id)

# ─── Головний обробник — Gen 1 сигнатура ───
def main(event, context):
    """
    Точка входу для Gen 1 Pub/Sub тригера.

    event:   dict з полями 'data' (base64) та 'attributes'
    context: метадані події — context.event_id, context.timestamp
    """
    event_id = context.event_id

    # 1. Перевірка наявності даних
    if 'data' not in event:
        print(f"[WARNING] Empty Pub/Sub message | event_id={event_id}")
        return  # Повертаємо None → Gen 1 вважає це успіхом (ack)

    # 2. Перевірка ідемпотентності
    if _is_duplicate(event_id):
        print(f"[INFO] Duplicate message skipped | event_id={event_id}")
        return
    
    # 3 Декодування та парсинг
    try:
        raw     = base64.b64decode(event['data']).decode('utf-8')
        payload = json.loads(raw)
    except (ValueError, json.JSONDecodeError) as e:
        # Невалідний JSON — не робимо retry (він не виправить проблему)
        print(f"[ERROR] Invalid message format: {e} | event_id={event_id}")
        return

    event_type = payload.get("event_type")
    print(f"[INFO] Processing event_type={event_type} | event_id={event_id}")

    # 4. Маршрутизація
    if event_type == "booking_created":
        _dispatch_booking_created(payload, event_id)
    elif event_type == "apartment_added":
        _dispatch_apartment_added(payload, event_id)
    else:
        print(f"[WARNING] Unknown event_type={event_type} | event_id={event_id}")
        return
    
    # 5. Записуємо факт обробки після успішної відправки
    _mark_processed(event_id, event_type)