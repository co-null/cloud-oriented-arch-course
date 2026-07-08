import base64
import json

def main(event, context):
    """
    Обробляє повідомлення з Dead Letter Queue.
    Gen 1 сигнатура: (event, context)
    """
    # Pub/Sub автоматично додає метадані про причину потрапляння в DLQ
    attrs              = event.get("attributes", {})
    source_sub         = attrs.get("CloudPubSubDeadLetterSourceSubscription", "unknown")
    delivery_attempts  = attrs.get("CloudPubSubDeadLetterSourceDeliveryAttempts", "unknown")

    raw = (
        base64.b64decode(event['data']).decode('utf-8')
        if 'data' in event else "<empty>"
    )

    # Структурований лог для Cloud Logging
    print(json.dumps({
        "severity":            "ERROR",
        "message":             "Message moved to Dead Letter Queue",
        "event_id":            context.event_id,
        "source_subscription": source_sub,
        "delivery_attempts":   delivery_attempts,
        "original_message":    raw[:500]
    }))
