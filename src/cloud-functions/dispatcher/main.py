import base64
import json
import os
import uuid
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry
from google.cloud import firestore
from google.cloud import pubsub_v1
from datetime import datetime, timezone
from flask import Request

EMAIL_SENDER_URL = os.environ.get("EMAIL_SENDER_URL")
ADMIN_EMAIL      = os.environ.get("ADMIN_EMAIL")
PROJECT_ID       = os.environ.get("GCP_PROJECT")
PUBSUB_TOPIC     = os.environ.get("PUBSUB_TOPIC")

# ─── Ініціалізація (один раз при cold start) ───
_db = firestore.Client(project=PROJECT_ID)
_publisher = pubsub_v1.PublisherClient()

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

# ─── Idempotency helpers ───
def _is_duplicate(event_id: str) -> bool:
    doc = _db.collection("processed_notifications").document(event_id).get()
    return doc.exists

def _mark_processed(event_id: str, event_type: str):
    _db.collection("processed_notifications").document(event_id).set({
        "processed_at": datetime.now(timezone.utc).isoformat(),
        "event_type":   event_type
    })

# ─── Booking Timeline ───
def _record_booking_step(booking_id: str, step: str, correlation_id: str, details: dict = None):
    """
    Записує крок у Booking Timeline для відстеження прогресу процесу.
    Не кидає виняток при помилці — не блокує основну логіку.
    """
    if not booking_id:
        return
    try:
        booking_ref = _db.collection("bookings").document(booking_id)
        booking_ref.set({
            "current_step":   step,
            "correlation_id": correlation_id,
            "updated_at":     firestore.SERVER_TIMESTAMP,
        }, merge=True) #  merge=True: не перезаписуємо решту полів бронювання — dispatcher бачить тільки свої кроки, а не весь документ.
        booking_ref.collection("timeline").add({
            "step":      step,
            "details":   details or {},
            "timestamp": firestore.SERVER_TIMESTAMP,
        })
    except Exception as e:
        print(f"[WARNING] Failed to record booking step: {e} | booking_id={booking_id}")

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
    elif 400 <= resp.status_code < 500:
        # Клієнтська помилка — не кидаємо виняток, не робимо retry
        print(f"[ERROR] Bad request to email-sender: {resp.text[:200]} | event_id={event_id}")
        return False
    else:
        # Серверна помилка — кидаємо виняток → Pub/Sub зробить retry
        raise RuntimeError(
            f"email-sender returned {resp.status_code}: "
            f"{resp.text[:200]} | event_id={event_id}"
        )

# ─── Pub/Sub publisher helper ──────────────────────────────────────────────────

def _publish_event(event: dict, event_id: str):
    """
    Публікує нову подію в Pub/Sub топік.

    Чому це безпечно:
    - Новий event отримає власний унікальний message_id від Pub/Sub
    - Idempotency check у dispatcher спрацює на цей новий ID
    - Якщо publish не вдався — кидаємо RuntimeError → Pub/Sub зробить
      retry для ПОТОЧНОГО event (booking_created), а не нового

    :param event:    dict з даними події (буде серіалізовано в JSON → base64)
    :param event_id: event_id батьківської події (для логування)
    """
    if not PUBSUB_TOPIC:
        raise RuntimeError("PUBSUB_TOPIC env var is not set")

    topic_path = _publisher.topic_path(PROJECT_ID, PUBSUB_TOPIC)
    data_bytes = json.dumps(event, ensure_ascii=False).encode("utf-8")

    try:
        future = _publisher.publish(topic_path, data=data_bytes)
        new_message_id = future.result(timeout=10)   # чекаємо підтвердження від Pub/Sub
        print(
            f"[INFO] Published event_type={event.get('event_type')} "
            f"new_message_id={new_message_id} | parent_event_id={event_id}"
        )
    except Exception as e:
        # Кидаємо RuntimeError → dispatcher поверне 500 → Pub/Sub зробить
        # retry для батьківського event → booking_created буде оброблено знову
        # Але лист користувачу вже відправлено! Тому idempotency check
        # на рівні _mark_processed захистить від дублювання листа.
        raise RuntimeError(f"Failed to publish event: {e} | parent_event_id={event_id}")


# ─── Обробники подій ───
def _dispatch_booking_created(event: dict, event_id: str):
    """
    Обробляє подію booking_created:
    1. Відправляє лист підтвердження користувачу
    2. Публікує нову подію owner_booking_notification у Pub/Sub
       → dispatcher обробить її окремо і надішле лист власнику квартири
    """
    booking_id     = event.get("booking_id", event_id)
    correlation_id = event.get("correlation_id", event_id)  # fallback на event_id

    # ── Крок 1: лист користувачу
    payload = {
        "recipient":    event["user_id"],
        "user_name":    event.get("user_name", "Клієнт"),
        "booking_id":   event.get("booking_id", event_id),
        "apartment_id": event.get("apartment_id", event_id),
        "description":  event.get("description", "не вказано"),
        "rooms":        event.get("rooms", "не вказано"),
        "address":      event.get("address", "не вказано"),
        "start_date":   event["start_date"],
        "end_date":     event["end_date"],
        "price":        event.get('price', '—')
    }
    _record_booking_step(booking_id, "DISPATCHER_RECEIVED", correlation_id)
    _call_email_sender("/send-booking-email", payload, event_id)
    _record_booking_step(booking_id, "EMAIL_SENT", correlation_id,
                         details={"recipient": event.get("user_id")})

    # ── Крок 2: публікуємо нову подію для листа власнику ─────────────────────
    # Формуємо окрему подію — dispatcher отримає її як нове повідомлення
    # зі своїм унікальним message_id від Pub/Sub
    owner_notification_event = {
        "event_type":     "owner_booking_notification",   
        "correlation_id": correlation_id,                 # зберігаємо той самий correlation_id для трасування
        "booking_id":     event.get("booking_id", event_id),
        "apartment_id":   event.get("apartment_id"),
        "address":        event.get("address", "не вказано"),
        "rooms":          event.get("rooms", "не вказано"),
        "description":    event.get("description", "не вказано"),
        "start_date":     event["start_date"],
        "end_date":       event["end_date"],
        "price":          event.get("price", "—"),
        "user_name":      event.get("user_name", "Клієнт"),  # ім'я орендаря для листа власнику
        "user_email":     event.get("user_id"),              # email орендаря (user_id = email у вашій системі)
    }
    _publish_event(owner_notification_event, event_id)
    _record_booking_step(
        booking_id, "OWNER_NOTIFICATION_QUEUED", correlation_id,
        details={"apartment_id": event.get("apartment_id")}
    )

def _dispatch_owner_booking_notification(event: dict, event_id: str):
    """
    Обробляє подію owner_booking_notification:
    1. Отримує email власника квартири з Firestore
    2. Відправляє лист власнику з деталями бронювання

    Цей обробник викликається окремим Pub/Sub повідомленням,
    тому має власний idempotency check і незалежний retry.
    """
    booking_id     = event.get("booking_id", event_id)
    correlation_id = event.get("correlation_id", event_id)
    apartment_id   = event.get("apartment_id")
    owner_email    = event.get("owner_email")

    _record_booking_step(booking_id, "OWNER_NOTIFICATION_RECEIVED", correlation_id)

    # ── Відправляємо лист власнику ────────────────────────────────────────────
    # Використовуємо /send-email (plain-text режим), оскільки шаблон booking_created.html
    # орієнтований на орендаря. Для власника формуємо окремий текст.
    # (Студентам запропонувати створити окремий HTML-шаблон як розширення завдання)
    payload = {
        "recipient": owner_email,
        "subject":   f"🏠 Нове бронювання вашої квартири: {event.get('address', apartment_id)}",
        "text": (
            f"Вашу квартиру заброньовано!\n\n"
            f"Квартира: {event.get('address', 'не вказано')}\n"
            f"Орендар: {event.get('user_name', 'Клієнт')} ({event.get('user_email', 'не вказано')})\n"
            f"Дати: {event.get('start_date')} — {event.get('end_date')}\n"
            f"Кімнат: {event.get('rooms', '—')}\n"
            f"Ціна/доба: {event.get('price', '—')} UAH\n"
            f"ID бронювання: {event.get('booking_id', event_id)}\n\n"
            f"З повагою, команда ApartHub"
        )
    }
    _call_email_sender("/send-email", payload, event_id)
    _record_booking_step(
        booking_id, "OWNER_EMAIL_SENT", correlation_id,
        details={"recipient": owner_email}
    )


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
            f"Кількість кімнат: {event.get('rooms', 'не вказано')}\n"
            f"Опис: {event.get('description', 'не вказано')}\n"
            f"Ціна/день: {event.get('price', '—')} UAH"
        )
    }
    _call_email_sender("/send-email", payload, event_id)

# ─── Головний обробник — HTTP сигнатура ───
def main(request: Request):
    """
    Точка входу для HTTP-тригера (Pub/Sub push-підписка).
    Підтримує event_type:
      - booking_created              → лист користувачу + publish owner_booking_notification
      - owner_booking_notification   → лист власнику квартири
      - apartment_added              → лист адміну

    Pub/Sub надсилає POST з JSON-тілом:
    {
      "message": {
        "data": "<base64>",
        "messageId": "...",
        "attributes": {}
      },
      "subscription": "projects/.../subscriptions/..."
    }

    Коди відповіді:
      200 → Pub/Sub ACK (повідомлення оброблено або навмисно відкинуто)
      500 → Pub/Sub NACK → retry → після max_delivery_attempts → DLQ
    """

    # 1. Валідація конверта Pub/Sub push
    envelope = request.get_json(silent=True)
    if not envelope or "message" not in envelope:
        print("[WARNING] Invalid Pub/Sub push envelope")
        # 400 → Pub/Sub вважатиме це постійною помилкою і теж відправить в DLQ
        return "Bad Request: missing message envelope", 400

    message  = envelope["message"]
    event_id = message.get("messageId") or message.get("message_id", "unknown")

    # 2. Порожнє повідомлення — ACK (не retry)
    if "data" not in message:
        print(f"[WARNING] Empty Pub/Sub message | event_id={event_id}")
        return "OK", 200

    # 3. Idempotency check
    if _is_duplicate(event_id):
        print(f"[INFO] Duplicate message skipped | event_id={event_id}")
        return "OK", 200  # ACK — вже оброблено раніше

    # 4. Декодування та парсинг
    try:
        raw     = base64.b64decode(message["data"]).decode("utf-8")
        payload = json.loads(raw)
    except (ValueError, json.JSONDecodeError) as e:
        # Битий формат — retry не допоможе → ACK і логуємо
        print(f"[ERROR] Invalid message format: {e} | event_id={event_id}")
        return "OK", 200

    event_type     = payload.get("event_type")
    correlation_id = payload.get("correlation_id", event_id)
    print(f"[INFO] Processing event_type={event_type} | event_id={event_id} | correlation_id={correlation_id}")

    # 5. Маршрутизація з обробкою помилок
    try:
        if event_type == "booking_created":
            _dispatch_booking_created(payload, event_id)
        elif event_type == "apartment_added":
            _dispatch_apartment_added(payload, event_id)
        elif event_type == "owner_booking_notification":
            _dispatch_owner_booking_notification(payload, event_id)
        else:
            # Невідомий тип — ACK, не retry (retry не виправить)
            print(f"[WARNING] Unknown event_type={event_type} | event_id={event_id}")
            return "OK", 200

    except RuntimeError as e:
        # Серверна помилка email-sender або мережева недоступність
        # → 500 → Pub/Sub NACK → retry → після 5 спроб → DLQ
        print(f"[ERROR] {e}")
        return f"Internal error: {e}", 500

    # 6. Записуємо факт успішної обробки
    _mark_processed(event_id, event_type)

    return "OK", 200