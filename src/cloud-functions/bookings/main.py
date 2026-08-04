import firebase_admin
from firebase_admin import credentials, firestore
from datetime import datetime, timezone
import requests, json, logging, uuid

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

def json_response(payload, status=200):
    """Формує (body, status, headers) кортеж для Cloud Functions."""
    return (json.dumps(payload, ensure_ascii=False), status,
            {**CORS_HEADERS, 'Content-Type': 'application/json'})


# Перевірка токена через Cloud Function
def verify_token_via_cloud_function(request):
    """Перевірка токена через окрему Cloud Function."""
    auth = request.headers.get("Authorization")
    if not auth:
        return None, json_response({"detail": "Відсутній токен"}, 401)

    response = requests.post(
        "https://europe-west1-cloud-oriented-arch-course.cloudfunctions.net/protected-api",
        headers={"Authorization": auth}
    )
    if response.status_code != 200:
        return None, json_response({"detail": "Некоректний токен"}, 401)

    return response.json(), None

def main(request):
    """Точка входу Cloud Function (HTTP trigger)."""

    # Preflight CORS запит
    if request.method == 'OPTIONS':
        return make_cors_response('', 204)

    user, error_resp = verify_token_via_cloud_function(request)
    if not user:
        return error_resp

    user_id = user.get("user")

    if request.method == 'POST':
        errors = []
        data = request.get_json(silent=True) or {}
        apartment_id = data.get('apartment_id')
        start_date = data.get('start_date')
        end_date = data.get('end_date')

        # Валідація обов’язкових полів
        if not all([apartment_id, start_date, end_date]):
            errors.append("Всі поля обов’язкові")
        else:
            # Валідація дат (перевіряємо лише якщо поля присутні)
            if start_date >= end_date:
                errors.append("Дата початку має бути меншою за дату завершення")

            # Перевірка apartment_id
            apartment_ref = db.collection('apartments').document(apartment_id)
            if not apartment_ref.get().exists:
                errors.append("Квартира не знайдена")

        if errors:
            return json_response({"detail": " ".join(errors)}, 400)

        # Транзакція для перевірки конфлікту та створення бронювання
        @firestore.transactional
        def transaction_func(transaction):
            bookings_ref = db.collection('bookings')
            conflict_query = bookings_ref.where('apartment_id', '==', apartment_id) \
                .where('start_date', '<=', end_date) \
                .where('end_date', '>=', start_date) \
                .limit(1)
            conflict = [doc for doc in conflict_query.stream(transaction=transaction)]
            if conflict:
                raise Exception('Квартира вже заброньована на ці дати')

            booking_data = {
                'user_id': user_id,
                'apartment_id': apartment_id,
                'start_date': start_date,
                'end_date': end_date,
                'created_at': datetime.now(timezone.utc).isoformat()
            }
            new_id = str(uuid.uuid4())
            doc_ref = bookings_ref.document(new_id)
            transaction.set(doc_ref, booking_data)

        try:
            transaction = db.transaction()
            transaction_func(transaction)

            db.collection('booking_logs').add({
                'user_id': user_id,
                'apartment_id': apartment_id,
                'start_date': start_date,
                'end_date': end_date,
                'status': 'success',
                'timestamp': datetime.now(timezone.utc).isoformat()
            })
            return json_response({'message': 'Бронювання створено'}, 201)

        except Exception as e:
            db.collection('booking_logs').add({
                'user_id': user_id,
                'apartment_id': apartment_id,
                'start_date': start_date,
                'end_date': end_date,
                'status': 'fail',
                'error': str(e),
                'timestamp': datetime.now(timezone.utc).isoformat()
            })
            return json_response({'error': str(e)}, 409)

    elif request.method == 'GET':
        bookings_ref = db.collection('bookings')
        bookings_query = bookings_ref.where('user_id', '==', user_id)
        bookings = bookings_query.stream()
        result = [doc.to_dict() for doc in bookings]
        return json_response(result, 200)

    return json_response({"detail": "Метод не підтримується"}, 405)