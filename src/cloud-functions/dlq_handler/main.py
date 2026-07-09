import base64
import json
import os
from datetime import datetime, timezone
from google.cloud import firestore, logging as cloud_logging

# ─── Ініціалізація (cold start) ───

_db          = firestore.Client()
_log_client  = cloud_logging.Client()
_logger      = _log_client.logger("dlq_handler")

PROJECT_ID = os.environ.get("GCP_PROJECT")

# ─── Збереження в Firestore для аудиту ───
def _store_dead_letter(event_id: str, record: dict):
    """
    Зберігає провалене повідомлення в Firestore-колекції dead_letters
    для подальшого ручного аналізу або повторної обробки.
    """
    from google.api_core.exceptions import AlreadyExists
    doc_ref = _db.collection("dead_letters").document(event_id)
    try:
        doc_ref.create({
            **record,
            "stored_at": datetime.now(timezone.utc).isoformat(),
            # TTL: видалити через 90 днів (потрібно увімкнути TTL policy
            # у Firestore Console на полі expire_at)
            "expire_at": datetime.fromtimestamp(
                datetime.now(timezone.utc).timestamp() + 90 * 24 * 3600,
                tz=timezone.utc
            )
        })
        print(f"[INFO] Dead letter stored in Firestore | event_id={event_id}")
    except AlreadyExists:
        print(f"[INFO] Dead letter already stored | event_id={event_id}")

# ─── Структуроване логування в Cloud Logging ───
def _log_dead_letter(event_id: str, record: dict):
    """
    Структурований лог у Cloud Logging — доступний у Log Explorer
    та може тригерити log-based алерти.
    """
    _logger.log_struct(
        {
            "severity":   "ERROR",
            "message":    "Dead letter received",
            "event_id":   event_id,
            **record
        },
        severity="ERROR"
    )

# ─── Головний обробник — Gen 1 Pub/Sub background тригер ───
def main(event, context):
    """
    Точка входу для Gen 1 Pub/Sub тригера на notification-dlq топіку.
    event:   dict з полями 'data' (base64) та 'attributes'
    context: метадані — context.event_id, context.timestamp
    """

    event_id = context.event_id

    # 1. Витягуємо DLQ-метадані, які Pub/Sub додає автоматично
    attributes = event.get("attributes", {})
    source_subscription  = attributes.get("CloudPubSubDeadLetterSourceSubscription", "unknown")
    source_project       = attributes.get("CloudPubSubDeadLetterSourceSubscriptionProject", PROJECT_ID or "unknown")
    delivery_count       = attributes.get("CloudPubSubDeadLetterSourceDeliveryCount", "unknown")
    original_publish_time = attributes.get("CloudPubSubDeadLetterSourceTopicPublishTime", "unknown")
    delivery_error       = attributes.get("CloudPubSubDeadLetterSourceDeliveryErrorMessage", "no error message provided")

    # 2. Декодуємо оригінальне повідомлення
    raw_data    = None
    parsed_data = None

    if "data" in event:
        try:
            raw_data    = base64.b64decode(event["data"]).decode("utf-8")
            parsed_data = json.loads(raw_data)
        except (ValueError, json.JSONDecodeError):
            # Бите повідомлення — зберігаємо як є
            parsed_data = {"raw": raw_data}

    # 3. Формуємо уніфікований запис
    record = {
        "event_id":             event_id,
        "dlq_received_at":      context.timestamp,
        # Оригінальні дані
        "original_payload":     parsed_data,
        # DLQ-метадані від Pub/Sub
        "source_subscription":  source_subscription,
        "source_project":       source_project,
        "delivery_count":       delivery_count,
        "original_publish_time": original_publish_time,
        "delivery_error":       delivery_error,
        # Додаткові атрибути (кастомні, якщо є)
        "custom_attributes": {
            k: v for k, v in attributes.items()
            if not k.startswith("CloudPubSub")
        }
    }

    # 4. Структурований лог — видно в Cloud Logging / Log Explorer
    print(
        f"[DEAD LETTER] event_id={event_id} | "
        f"delivery_count={delivery_count} | "
        f"source={source_subscription} | "
        f"error={delivery_error} | "
        f"payload={raw_data}"
    )

    # 5. Структурований лог у Cloud Logging (для log-based alerting)
    try:
        _log_dead_letter(event_id, record)
    except Exception as e:
        # Не блокуємо основну логіку якщо Cloud Logging недоступний
        print(f"[WARNING] Cloud Logging write failed: {e}")

    # 6. Зберігаємо в Firestore для аудиту та можливого replay
    try:
        _store_dead_letter(event_id, record)
    except Exception as e:
        print(f"[WARNING] Firestore write failed: {e}")

    # 7. Аналіз типу події для більш детального логування
    if parsed_data and isinstance(parsed_data, dict):
        event_type = parsed_data.get("event_type", "unknown")
        print(
            f"[DEAD LETTER DETAIL] event_type={event_type} | "
            f"booking_id={parsed_data.get('booking_id', 'n/a')} | "
            f"user_id={parsed_data.get('user_id', 'n/a')}"
        )

    # DLQ handler завжди повертає успіх (None) — не ретраїмо DLQ-повідомлення.
    # Якщо тут виникне виняток — Gen 1 зробить retry самого dlq_handler,
    # тому всі зовнішні виклики (Firestore, Logging) обгорнуті в try/except.
    return
