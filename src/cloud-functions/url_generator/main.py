"""
Генерує Signed URL V4 для прямого завантаження CSV в GCS.
Записує pending-статус імпорту в Firestore.

Інтегрується з існуючою системою: записує в ту ж колекцію Firestore.
"""
import datetime
import json
import os
import uuid
import flask
import google.auth
from google.auth import impersonated_credentials
from google.cloud import firestore, storage

IMPORT_BUCKET = os.environ.get("IMPORT_BUCKET")
SIGNING_SA    = os.environ.get("SIGNING_SA")
GCP_PROJECT   = os.environ.get("GCP_PROJECT")

MAX_FILE_SIZE_MB = 50  # Максимально дозволений розмір CSV

# ─── Ініціалізація клієнтів ───────────────────────────────
_db = firestore.Client(project=GCP_PROJECT)

def log(severity: str, message: str, **kwargs):
    entry = {
        "severity": severity,
        "message": message,
        "function": "generate_import_url",
        **kwargs
    }
    print(json.dumps(entry))


def generate_import_url(request: flask.Request) -> flask.Response:
    """
    HTTP endpoint для отримання Signed URL.
    
    POST body:
    {
        "file_size_bytes": 102400,
        "requested_by": "admin@company.com"   // опціонально
    }
    
    Response:
    {
        "upload_url": "https://storage.googleapis.com/...",
        "import_id": "uuid4",
        "expires_in_seconds": 900
    }
    """
    
    # CORS preflight
    if request.method == "OPTIONS":
        return (b"", 204, {
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type, Authorization",
            "Access-Control-Max-Age": "3600",
        })
    
    cors_headers = {"Access-Control-Allow-Origin": "*"}
    
    if request.method != "POST":
        return flask.make_response(
            json.dumps({"error": "Only POST allowed"}), 405, cors_headers
        )
    
    # Парсимо тіло запиту
    body = request.get_json(silent=True) or {}
    
    file_size_bytes = body.get("file_size_bytes", 0)
    requested_by    = body.get("requested_by", "unknown")
    
    # Валідація розміру
    if file_size_bytes > MAX_FILE_SIZE_MB * 1024 * 1024:
        return flask.make_response(
            json.dumps({"error": f"File too large. Max {MAX_FILE_SIZE_MB}MB"}),
            400, cors_headers
        )
    
    # Генеруємо унікальний import_id
    import_id = str(uuid.uuid4())
    
    # Безпечний шлях — клієнт не може впливати на нього
    blob_name = f"imports/{import_id}/apartments.csv"
    
    log("INFO", "Generating import signed URL",
        import_id=import_id,
        blob_name=blob_name,
        requested_by=requested_by,
        file_size_bytes=file_size_bytes)
    
    try:
        # ─── Keyless Signed URL V4 ────────────────────────────
        source_creds, _ = google.auth.default()
        
        signing_creds = impersonated_credentials.Credentials(
            source_credentials=source_creds,
            target_principal=SIGNING_SA,
            target_scopes=["https://www.googleapis.com/auth/cloud-platform"],
            lifetime=300,
        )
        
        _sb = storage.Client(credentials=signing_creds)
        blob = _sb.bucket(IMPORT_BUCKET).blob(blob_name)
        
        signed_url = blob.generate_signed_url(
            version="v4",
            expiration=datetime.timedelta(minutes=15),
            method="PUT",
            content_type="text/csv",   # Підписуємо Content-Type!
            credentials=signing_creds,
        )
        
        # ─── Записуємо pending-статус у Firestore ─────────────
        _db.collection("apartment_imports").document(import_id).set({
            "import_id": import_id,
            "status": "pending_upload",
            "blob_name": blob_name,
            "bucket": IMPORT_BUCKET,
            "requested_by": requested_by,
            "file_size_bytes": file_size_bytes,
            "created_at": firestore.SERVER_TIMESTAMP,
        })
        
        log("INFO", "Signed URL generated",
            import_id=import_id,
            blob_name=blob_name)
        
        return flask.make_response(
            json.dumps({
                "upload_url": signed_url,
                "import_id": import_id,
                "expires_in_seconds": 900,
                "instructions": {
                    "method": "PUT",
                    "content_type": "text/csv",
                    "note": "Content-Type header must exactly match 'text/csv'"
                }
            }),
            200, cors_headers
        )
        
    except Exception as e:
        log("ERROR", "Failed to generate signed URL",
            error=str(e),
            error_type=type(e).__name__)
        return flask.make_response(
            json.dumps({"error": "Internal server error"}), 500, cors_headers
        )