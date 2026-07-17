"""
Обробляє CSV-файл квартир, завантажений в GCS.

Патерни:
  - Idempotency через Firestore ledger (bucket + name + generation)
  - Класифікація помилок: permanent vs transient
  - Переміщення невалідних файлів у quarantine/
  - Публікація подій в існуючий booking-events топік
  - Structured JSON logging
  - Зв'язок з існуючим state machine через той самий Pub/Sub топік
"""
import base64
import csv
import io
import json
import os
import re
import uuid
from datetime import datetime, timezone, timedelta
from google.cloud import firestore, pubsub_v1, storage

# ─── Ініціалізація клієнтів ───────────────────────────────
_storage_client   = None
_firestore_client = None
_pubsub_publisher = None

def get_storage():
    global _storage_client
    if _storage_client is None:
        _storage_client = storage.Client()
    return _storage_client

def get_db():
    global _firestore_client
    if _firestore_client is None:
        _firestore_client = firestore.Client()
    return _firestore_client

def get_publisher():
    global _pubsub_publisher
    if _pubsub_publisher is None:
        _pubsub_publisher = pubsub_v1.PublisherClient()
    return _pubsub_publisher


# ─── Конфігурація ─────────────────────────────────────────
IMPORT_BUCKET = os.environ.get("IMPORT_BUCKET")
TOPIC_NAME    = os.environ.get("TOPIC_NAME")
GCP_PROJECT   = os.environ.get("GCP_PROJECT")

REQUIRED_COLUMNS = {"address", "price", "rooms", "description", "owner_email"}
MAX_ROWS         = 5_000
MAX_SIZE_MB      = 10

# ─── Власні класи помилок ─────────────────────────────────
class PermanentImportError(Exception):
    """Невалідний файл — retry не допоможе."""
    pass

class TransientImportError(Exception):
    """Тимчасова помилка інфраструктури — retry потрібен."""
    pass


def log(severity: str, message: str, **kwargs):
    entry = {
        "severity": severity,
        "message": message,
        "function": "import_apartments",
        "environment": ENVIRONMENT,
        **kwargs
    }
    print(json.dumps(entry))


# ─── Валідація CSV ────────────────────────────────────────
def validate_and_parse_csv(csv_bytes: bytes) -> list[dict]:
    """
    Парсить і валідує CSV.
    Raises PermanentImportError при невалідних даних.
    Returns: список рядків як dict
    """
    size_mb = len(csv_bytes) / (1024 * 1024)
    if size_mb > MAX_SIZE_MB:
        raise PermanentImportError(
            f"File too large: {size_mb:.2f}MB (max {MAX_SIZE_MB}MB)"
        )
    
    try:
        csv_text = csv_bytes.decode("utf-8")
    except UnicodeDecodeError:
        raise PermanentImportError("File encoding is not UTF-8")
    
    try:
        reader = csv.DictReader(io.StringIO(csv_text))
        headers = set(reader.fieldnames or [])
    except csv.Error as e:
        raise PermanentImportError(f"Invalid CSV format: {e}")
    
    missing = REQUIRED_COLUMNS - headers
    if missing:
        raise PermanentImportError(
            f"Missing required columns: {sorted(missing)}"
        )
    
    rows = []
    errors = []
    
    for i, row in enumerate(reader):
        if i >= MAX_ROWS:
            raise PermanentImportError(
                f"Too many rows: >{MAX_ROWS}. Split into smaller files."
            )
        
        row_errors = []
        
        # CSV Injection захист
        for key, value in row.items():
            if value and len(value) > 0 and value[0] in ("=", "+", "-", "@", "\t", "\r"):
                row[key] = "'" + value
        
        # Валідація price
        try:
            price = float(row.get("price", ""))
            if price <= 0 or price > 100_000:
                row_errors.append(f"price out of range: {price}")
        except (ValueError, TypeError):
            row_errors.append(
                f"price is not a number: {row.get('price')}"
            )
        
        # Валідація rooms
        try:
            rooms = int(row.get("rooms", ""))
            if rooms < 1 or rooms > 20:
                row_errors.append(f"rooms out of range: {rooms}")
        except (ValueError, TypeError):
            row_errors.append(f"rooms is not an integer: {row.get('rooms')}")
        
        # Базова валідація email
        email = row.get("owner_email", "")
        if not re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", email):
            row_errors.append(f"Invalid email: {email}")
        
        if row_errors:
            errors.append({"row": i + 2, "errors": row_errors})
        else:
            rows.append(row)
    
    if errors:
        # Якщо є помилки валідації — permanent error
        error_summary = json.dumps(errors[:10])  # Перші 10 помилок
        raise PermanentImportError(
            f"Validation errors in {len(errors)} rows: {error_summary}"
        )
    
    return rows


# ─── Запис у Firestore ────────────────────────────────────
def save_apartments_to_firestore(rows: list[dict], import_id: str) -> int:
    """
    Batch-записує квартири в Firestore.
    Використовує set() для idempotency (повторний запис = перезапис).
    Returns: кількість записаних рядків
    """
    db = get_db()
    batch = db.batch()
    batch_size = 0
    total_written = 0
    
    for row in rows:
        # Генеруємо детермінований ID на основі унікальних полів
        # Це гарантує idempotency: повторний імпорт не створить дублікати
        unique_key = f"{row['owner_email']}_{row['rooms']}_{row['address']}"
        apartment_id = str(uuid.uuid5(uuid.NAMESPACE_DNS, unique_key))
        
        doc_ref = db.collection("apartments").document(apartment_id)
        
        apartment_data = {
            "apartment_id": apartment_id,
            "address":      row.get("address", "").strip(),
            "price":        float(row.get("price", 0)),
            "rooms":        int(row.get("rooms", 1)),
            "user_id":      row.get("owner_email", "").strip(),
            "description":  row.get("description", "").strip(),
            
            # Мета-дані імпорту
            "status":          "available",
            "source":          "csv_import",
            "import_id":       import_id,
            "imported_at":     firestore.SERVER_TIMESTAMP,
        }
        
        batch.set(doc_ref, apartment_data, merge=True)  # merge=True = upsert
        batch_size += 1
        total_written += 1
        
        # Firestore batch обмежений 500 операціями
        if batch_size >= 400:
            batch.commit()
            log("INFO", f"Batch committed: {total_written} apartments written so far",
                import_id=import_id)
            batch = db.batch()
            batch_size = 0
    
    # Фінальний batch
    if batch_size > 0:
        batch.commit()
    
    return total_written


# ─── Публікація подій ─────────────────────────────────────
def publish_apartment_events(rows: list[dict], import_id: str):
    """
    Публікує події в існуючий apartment-events топік.
    Новоімпортовані квартири проходять через той самий dispatcher.
    """
    publisher = get_publisher()
    topic_path = publisher.topic_path(GCP_PROJECT, TOPIC_NAME)
    
    for row in rows:
        unique_key = f"{row['owner_email']}_{row['rooms']}_{row['address']}"
        apartment_id = str(uuid.uuid5(uuid.NAMESPACE_DNS, unique_key))
        
        event_payload = {
            "event_type": "apartment_added",
            "source": "csv_import",
            "import_id": import_id,
            "apartment_id": apartment_id,
            "owner_email": row.get("owner_email"),
            "timestamp": datetime.utcnow().isoformat()
        }
        
        publisher.publish(
            topic_path,
            data=json.dumps(event_payload).encode("utf-8"),
            event_type="apartment.created",
            source="csv_import"
        )


# ─── Переміщення у карантин ───────────────────────────────
def move_to_quarantine(bucket_name: str, blob_name: str, reason: str):
    """Переміщає невалідний файл у quarantine/ з анотацією причини."""
    try:
        client = get_storage()
        bucket = client.bucket(bucket_name)
        source_blob = bucket.blob(blob_name)
        
        quarantine_name = blob_name.replace("imports/", "quarantine/", 1)
        
        # Копіюємо з метаданими про причину
        new_blob = bucket.copy_blob(source_blob, bucket, quarantine_name)
        new_blob.metadata = {"quarantine_reason": reason[:1000]}
        new_blob.patch()
        
        # Видаляємо оригінал
        source_blob.delete()
        
        log("INFO", "File moved to quarantine",
            original=blob_name,
            quarantine=quarantine_name,
            reason=reason[:200])
    except Exception as e:
        log("WARNING", "Failed to move file to quarantine",
            blob_name=blob_name,
            error=str(e))


# ─── Головна функція ──────────────────────────────────────
def import_apartments(event, context):
    """
    Gen 1 Cloud Function: Pub/Sub trigger.
    Обробляє CSV-файл квартир при OBJECT_FINALIZE.
    """
    
    # ─── Декодуємо Pub/Sub повідомлення ──────────────────
    try:
        pubsub_data   = base64.b64decode(event["data"]).decode("utf-8")
        gcs_object    = json.loads(pubsub_data)
    except Exception as e:
        log("ERROR", "Cannot decode Pub/Sub message",
            error=str(e),
            event_id=context.event_id)
        return  # ACK — пошкоджене повідомлення не має сенсу retry

    bucket_name = gcs_object.get("bucket", "")
    blob_name   = gcs_object.get("name", "")
    generation  = gcs_object.get("generation", "0")
    size_bytes  = int(gcs_object.get("size", 0))
    event_type  = event.get("attributes", {}).get("eventType", "")
    
    log("INFO", "CSV import event received",
        bucket=bucket_name,
        blob_name=blob_name,
        generation=generation,
        size_bytes=size_bytes,
        event_type=event_type,
        event_id=context.event_id)
    
    # ─── Базові фільтри ───────────────────────────────────
    if event_type != "OBJECT_FINALIZE":
        log("INFO", "Skipping non-finalize event", event_type=event_type)
        return
    
    if not blob_name.startswith("imports/"):
        log("INFO", "Skipping: not in imports/ folder", blob_name=blob_name)
        return
    
    if not blob_name.endswith(".csv"):
        log("INFO", "Skipping: not a CSV file", blob_name=blob_name)
        return
    
    # ─── Vitягуємо import_id з шляху ──────────────────────
    # Формат: imports/{import_id}/apartments.csv
    parts = blob_name.split("/")
    if len(parts) < 3:
        log("WARNING", "Unexpected blob path format", blob_name=blob_name)
        return
    
    import_id = parts[1]
    
    # ─── Idempotency check ────────────────────────────────
    idempotency_key = f"{bucket_name}__{blob_name}__{generation}"
    db = get_db()
    ledger_ref = db.collection("import_ledger").document(
        re.sub(r"[/.]", "_", idempotency_key)
    )
    
    ledger_doc = ledger_ref.get()
    if ledger_doc.exists:
        existing_status = ledger_doc.to_dict().get("status")
        if existing_status == "completed":
            log("INFO", "Duplicate event — already completed, skipping",
                import_id=import_id,
                generation=generation)
            return
    
    # Записуємо "processing" статус
    ttl_time = datetime.now(timezone.utc) + timedelta(days=7)
    ledger_ref.set({
        "status":      "processing",
        "import_id":   import_id,
        "blob_name":   blob_name,
        "generation":  generation,
        "started_at":  datetime.now(timezone.utc).isoformat(),
        "ttl":         ttl_time,
    })
    
    # Також оновлюємо основний документ імпорту
    import_doc_ref = db.collection("apartment_imports").document(import_id)
    import_doc_ref.set({
        "status":       "processing",
        "blob_name":    blob_name,
        "generation":   generation,
        "size_bytes":   size_bytes,
        "started_at":   firestore.SERVER_TIMESTAMP,
    }, merge=True)
    
    try:
        # ─── Завантажуємо файл ────────────────────────────
        log("INFO", "Downloading CSV from GCS",
            import_id=import_id,
            blob_name=blob_name)
        
        client = get_storage()
        bucket = client.bucket(bucket_name)
        blob = bucket.blob(blob_name)
        
        try:
            csv_bytes = blob.download_as_bytes()
        except Exception as e:
            raise TransientImportError(
                f"Failed to download from GCS: {e}"
            )
        
        # ─── Валідуємо і парсимо CSV ──────────────────────
        # PermanentImportError якщо невалідний
        rows = validate_and_parse_csv(csv_bytes)
        
        log("INFO", "CSV validated successfully",
            import_id=import_id,
            row_count=len(rows))
        
        # ─── Записуємо в Firestore ────────────────────────
        written_count = save_apartments_to_firestore(rows, import_id)
        
        # ─── Публікуємо події в існуючий топік ───────────
        try:
            publish_apartment_events(rows, import_id)
        except Exception as e:
            # Не провалюємо весь імпорт через помилку публікації
            log("WARNING", "Failed to publish some events",
                import_id=import_id,
                error=str(e))
        
        # ─── Оновлюємо статус успіху ─────────────────────
        ledger_ref.update({
            "status":       "completed",
            "completed_at": datetime.now(timezone.utc).isoformat(),
            "rows_written": written_count,
        })
        
        import_doc_ref.update({
            "status":       "completed",
            "rows_written": written_count,
            "completed_at": firestore.SERVER_TIMESTAMP,
        })
        
        log("INFO", "Import completed successfully",
            import_id=import_id,
            rows_written=written_count)
    
    except PermanentImportError as e:
        # Невалідний файл — не retry, переміщуємо в карантин
        log("ERROR", "Permanent import error — moving to quarantine",
            import_id=import_id,
            error=str(e))
        
        move_to_quarantine(bucket_name, blob_name, str(e))
        
        import_doc_ref.update({
            "status":      "rejected",
            "error":       str(e),
            "rejected_at": firestore.SERVER_TIMESTAMP,
        })
        
        ledger_ref.update({
            "status": "rejected",
            "error":  str(e),
        })
        
        return  # ACK — не retry
    
    except TransientImportError as e:
        # Тимчасова помилка — retry через Pub/Sub backoff
        log("WARNING", "Transient error — will retry",
            import_id=import_id,
            error=str(e))
        
        import_doc_ref.update({
            "status":          "retrying",
            "last_error":      str(e),
            "last_attempt_at": firestore.SERVER_TIMESTAMP,
        })
        
        ledger_ref.update({"status": "retrying"})
        
        raise  # NACK — Pub/Sub повторить
    
    except Exception as e:
        # Непередбачена помилка — теж retry
        log("ERROR", "Unexpected error — will retry",
            import_id=import_id,
            error=str(e),
            error_type=type(e).__name__)
        
        try:
            import_doc_ref.update({
                "status":          "retrying",
                "last_error":      f"Unexpected: {str(e)}",
                "last_attempt_at": firestore.SERVER_TIMESTAMP,
            })
        except Exception:
            pass
        
        raise  # NACK