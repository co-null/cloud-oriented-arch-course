from flask import Flask, request, jsonify
from flask_cors import CORS
import firebase_admin
from firebase_admin import credentials, firestore
from datetime import datetime, timezone
import requests

# Ініціалізація Firestore
cred = credentials.ApplicationDefault()
firebase_admin.initialize_app(cred)
db = firestore.client()

app = Flask(__name__)
CORS(app, supports_credentials=True)

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
def verify_token_via_cloud_function():
    auth = request.headers.get("Authorization")
    if not auth:
        return None, jsonify({"detail": "Відсутній токен"}), 401
    response = requests.post(
        "https://europe-west1-cloud-oriented-arch-course.cloudfunctions.net/protected-api",
        headers={"Authorization": auth}
    )
    if response.status_code != 200:
        return None, jsonify({"detail": "Некоректний токен"}), 401
    return response.json(), None, None

@app.route('/apartments', methods=['POST', 'GET'])
def apartments():
    if request.method == 'OPTIONS':
        # Preflight CORS request
        response = app.make_default_options_response()
        headers = response.headers

        headers['Access-Control-Allow-Origin'] = '*'
        headers['Access-Control-Allow-Methods'] = 'GET,POST,OPTIONS'
        headers['Access-Control-Allow-Headers'] = 'Authorization,Content-Type'
        headers['Access-Control-Max-Age'] = '3600'
        return response
    
    user, error_resp, error_code = verify_token_via_cloud_function()
    if not user:
        return error_resp, error_code

    if request.method == 'POST':
        data = request.get_json()
        errors = validate_apartment(data)
        if errors:
            return jsonify({"detail": " ".join(errors)}), 400
        db.collection('apartments').add(data)
        # Логування створення
        log_entry = {
            "user_id": user.get("sub"),
            "role": user.get("role"),
            "action": "create_apartment",
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "details": data
        }
        db.collection("logs").add(log_entry)
        return jsonify({"status": "created"}), 201

    elif request.method == 'GET':
        apartments = db.collection('apartments').stream()
        result = [doc.to_dict() for doc in apartments]
        return jsonify(result), 200

# entry_point для Cloud Functions
def main(request):
    return app(request)