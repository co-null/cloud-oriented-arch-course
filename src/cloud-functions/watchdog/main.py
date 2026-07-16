# src/cloud-functions/watchdog/main.py

"""
Watchdog Cloud Function
Виявляє бронювання що 'зависли' у стані processing.
Запускається Cloud Scheduler кожні 5 хвилин.
"""

import json
import logging
import os
import functions_framework
from datetime import datetime, timedelta, timezone
from google.cloud import firestore

logging.basicConfig(level=logging.INFO)

PROJECT_ID               = os.environ.get('GCP_PROJECT', '')
WATCHDOG_TIMEOUT_MINUTES = int(os.environ.get('WATCHDOG_TIMEOUT_MINUTES', '30'))

db = firestore.Client(project=PROJECT_ID)


def slog(severity: str, message: str, **extra):
    """Структурований JSON лог сумісний з Cloud Logging."""
    entry = {
        "severity": severity,
        "message":  message,
        "function": "watchdog",
        "ts":       datetime.now(timezone.utc).isoformat(),
        **extra
    }
    print(json.dumps(entry, ensure_ascii=False, default=str))


@functions_framework.http
def check_stuck_bookings(request):
    """
    HTTP endpoint що запускається Cloud Scheduler.
    Знаходить бронювання у стані 'processing' або 'started'
    що не оновлювались довше ніж WATCHDOG_TIMEOUT_MINUTES хвилин.
    """
    now       = datetime.now(timezone.utc)
    threshold = now - timedelta(minutes=WATCHDOG_TIMEOUT_MINUTES)

    slog("INFO", "Watchdog check started",
         threshold        = threshold.isoformat(),
         timeout_minutes  = WATCHDOG_TIMEOUT_MINUTES)

    found_count = 0
    stuck_count = 0

    try:
        candidates = (
            db.collection('bookings')
              .where('status', 'in', ['processing', 'started'])
              .stream()
        )

        for doc in candidates:
            found_count += 1
            data        = doc.to_dict()
            booking_id  = doc.id

            # Отримуємо час останнього оновлення
            updated_at = data.get('updated_at')
            if not updated_at:
                continue

            # Конвертуємо Firestore Timestamp → timezone-aware datetime в UTC
            if hasattr(updated_at, 'timestamp'):
                updated_dt = datetime.fromtimestamp(updated_at.timestamp(), tz=timezone.utc)
            else:
                continue

            # Ще не протерміновано — пропускаємо
            if updated_dt > threshold:
                continue

            # ── Знайшли "зависле" бронювання ────────────────────────────────
            stuck_count    += 1
            stuck_minutes   = int((now - updated_dt).total_seconds() / 60)
            correlation_id  = data.get('correlation_id', 'unknown')
            current_step    = data.get('current_step', 'unknown')

            slog("ERROR", "Stuck booking detected",
                 booking_id     = booking_id,
                 correlation_id = correlation_id,
                 current_step   = current_step,
                 stuck_minutes  = stuck_minutes,
                 last_updated   = updated_dt.isoformat())

            # ── Оновлюємо статус ─────────────────────────────────────────────
            doc.reference.update({
                'status':         'failed_timeout',
                'failure_reason': f"Stuck at step '{current_step}' for {stuck_minutes} min",
                'failed_at':      firestore.SERVER_TIMESTAMP,
                'updated_at':     firestore.SERVER_TIMESTAMP
            })

            # ── Записуємо у timeline ─────────────────────────────────────────
            doc.reference.collection('timeline').add({
                'step':      'WATCHDOG_TIMEOUT',
                'status':    'failed',
                'details': {
                    'stuck_minutes':   stuck_minutes,
                    'last_known_step': current_step
                },
                'timestamp': firestore.SERVER_TIMESTAMP
            })

    except Exception as e:
        slog("ERROR", f"Watchdog check failed with exception: {e}")
        return {"status": "error", "message": str(e)}, 500

    slog("INFO", "Watchdog check completed",
         checked    = found_count,
         stuck_found = stuck_count)

    return {
        "status":      "ok",
        "checked":     found_count,
        "stuck_found": stuck_count,
        "timestamp":   now.isoformat()
    }, 200