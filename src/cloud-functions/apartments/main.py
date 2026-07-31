import firebase_admin
from firebase_admin import credentials, firestore
from datetime import datetime, timezone
import requests, logging, json

# Ініціалізація Firestore
cred = credentials.ApplicationDefault()
firebase_admin.initialize_app(cred)
db = firestore.client()

CORS_HEADERS = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    'Access-Control-Allow-Headers': 'Authorization,Content-Type',
    'Access-Control-Max-Age': '3600',
}

def make_cors_response(body='', status=200, headers=None):
    response_headers = {
        **CORS_HEADERS,
    }
    if headers:
        response_headers.update(headers)
    return body, status, response_headers

def json_response(payload, status=200, headers=None):
    response_headers = {
        **CORS_HEADERS,
        'Content-Type': 'application/json',
    }

    if headers:
        response_headers.update(headers)

    return (
        json.dumps(payload, ensure_ascii=False, default=str),
        status,
        response_headers,
    )

# Валідація даних квартири
def validate_apartment(data):
    errors = []
    if not isinstance(data.get('address'), str) or not (5 <= len(data['address']) <= 100):
        errors.append("Адреса має бути рядком від 5 до 100 символів.")
    if not isinstance(data.get('rooms'), int) or not (0 < data['rooms'] < 10):
        errors.append("Кількість кімнат має бути цілим числом від 1 до 9.")
    if not isinstance(data.get('price'), int) or data['price'] <= 0:
        errors.append("Ціна має бути додатнім цілим числом.")
    if not isinstance(data.get('description'), str) or len(data['description']) > 500:
        errors.append("Опис має бути рядком до 500 символів.")
    return errors


# Перевірка токена через Cloud Function
def verify_token_via_cloud_function(request):
    auth_header = request.headers.get("Authorization")

    if not auth_header:
        return None, json_response({"detail": "Відсутній токен"}, 401)

    response = requests.post(
        "https://europe-west1-cloud-oriented-arch-course.cloudfunctions.net/protected-api",
        headers={"Authorization": auth_header},
    )

    if response.status_code != 200:
        return None, json_response({"detail": "Некоректний токен"}, 401)
    
    return response.json(), None

def create_apartment(request, user):
    data = request.get_json(silent=True)
    errors = validate_apartment(data)
    if errors:
        return json_response({"detail": " ".join(errors)}, 400)
    _, doc_ref = db.collection('apartments').add(data)

    log_entry = {
        "user_id": user.get("user"),
        "role": "no_role" if not user.get("role") else user.get("role"),
        "action": "create_apartment",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "details": {
            **data,
            "id": doc_ref.id,
        },
    }
    db.collection("logs").add(log_entry)

    return json_response({"status": "created"}, 201)

def get_apartments():
    apartments = db.collection('apartments').stream()
    result = [{**doc.to_dict(), "id": doc.id} for doc in apartments]
    return json_response(result, 200)

def main(request):
    if request.method == 'OPTIONS':
        return make_cors_response('', 204)

    user, error_resp = verify_token_via_cloud_function(request)

    if not user:
        return error_resp

    if request.method == 'POST':
        return create_apartment(request, user)

    if request.method == 'GET':
        return get_apartments()

    return json_response({"detail": "Метод не підтримується"}, 405)
