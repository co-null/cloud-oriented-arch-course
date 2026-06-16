from flask import Flask, request, jsonify, make_response
import firebase_admin
from firebase_admin import credentials, firestore
from datetime import datetime, timezone
import requests, logging, uuid

# Ініціалізація Firestore
cred = credentials.ApplicationDefault()
firebase_admin.initialize_app(cred)
db = firestore.client()

app = Flask(__name__)

def make_cors_response(response, status=200):
    resp = make_response(response, status)
    resp.headers['Access-Control-Allow-Origin'] = '*'
    resp.headers['Access-Control-Allow-Methods'] = 'GET,POST,OPTIONS'
    resp.headers['Access-Control-Allow-Headers'] = 'Authorization,Content-Type'
    resp.headers['Access-Control-Max-Age'] = '3600'
    return resp

# Перевірка токена через Cloud Function
def verify_token_via_cloud_function():
    auth = request.headers.get("Authorization")
    if not auth:
        return None, make_cors_response(jsonify({"detail": "Відсутній токен"}), 401)
    response = requests.post(
        "https://europe-west1-cloud-oriented-arch-course.cloudfunctions.net/protected-api",
        headers={"Authorization": auth}
    )
    if response.status_code != 200:
        return None, make_cors_response(jsonify({"detail": "Некоректний токен"}), 401)
    return response.json(), None

@app.route('/', methods=['POST', 'GET', 'OPTIONS'])
def bookings():
    if request.method == 'OPTIONS':
        return make_cors_response('', 204)
    
    user, error_resp = verify_token_via_cloud_function()
    if not user:
        return error_resp
    
    user_id = user.get("user")

    if request.method == 'POST':
        errors = []
        data = request.get_json()
        apartment_id = data.get('apartment_id')
        start_date = data.get('start_date')
        end_date = data.get('end_date')

        # Валідація обов’язкових полів
        if not all([apartment_id, start_date, end_date]):
            errors.append("Всі поля обов’язкові")

        # Валідація дат
        if start_date >= end_date:
            errors.append("Дата початку має бути меншою за дату завершення")

        # Перевірка apartment_id
        apartment_ref = db.collection('apartments').document(apartment_id)
        if not apartment_ref.get().exists:
            errors.append("Квартира не знайдена")

        if errors:
            return make_cors_response(jsonify({"detail": " ".join(errors)}), 400)
        
        # Транзакція для перевірки конфлікту та створення бронювання
        def transaction_func(transaction):
            bookings_ref = db.collection('bookings')
            conflict_query = bookings_ref.where('apartment_id', '==', apartment_id)\
                .where('start_date', '<', end_date)\
                .where('end_date', '>', start_date)\
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
            # Створюємо новий документ з унікальним ID
            new_id = str(uuid.uuid4())
            bookings_ref.document(new_id).set(booking_data, transaction=transaction)

        try:
            db.transaction(transaction_func)
            # Логування успішної спроби
            db.collection('booking_logs').add({
                'user_id': user_id,
                'apartment_id': apartment_id,
                'start_date': start_date,
                'end_date': end_date,
                'status': 'success',
                'timestamp': datetime.now(timezone.utc).isoformat()
            })
            return make_cors_response(jsonify({'message': 'Бронювання створено'}), 201)
        except Exception as e:
            # Логування невдалої спроби
            db.collection('booking_logs').add({
                'user_id': user_id,
                'apartment_id': apartment_id,
                'start_date': start_date,
                'end_date': end_date,
                'status': 'fail',
                'error': str(e),
                'timestamp': datetime.now(timezone.utc).isoformat()
            })
            return make_cors_response(jsonify({'error': str(e)}), 409)

    elif request.method == 'GET':
        bookings_ref = db.collection('bookings')
        bookings_query = bookings_ref.where('user_id', '==', user_id)
        bookings = bookings_query.stream()
        result = [doc.to_dict() for doc in bookings]
        return make_cors_response(jsonify(result), 200)
    
def main(request):
    with app.request_context(request.environ):
        return app.full_dispatch_request()