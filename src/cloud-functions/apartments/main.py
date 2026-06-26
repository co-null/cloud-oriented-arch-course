from flask import Flask, request, jsonify, make_response
import firebase_admin
from firebase_admin import credentials, firestore
from google.cloud import pubsub_v1
from google.api_core import exceptions
from datetime import datetime, timezone
import os, requests, logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Ініціалізація Firestore
cred = credentials.ApplicationDefault()
firebase_admin.initialize_app(cred)
db = firestore.client()

# Ініціалізація Pub/Sub клієнтів
publisher = pubsub_v1.PublisherClient()
project_id = os.environ.get('GCP_PROJECT', os.environ.get('GOOGLE_CLOUD_PROJECT'))

app = Flask(__name__)


def ensure_topic_exists(topic_name):
    """Створює топік, якщо він не існує"""
    topic_path = publisher.topic_path(project_id, topic_name)
    try:
        # Спроба отримати існуючий топік
        publisher.get_topic(request={"topic": topic_path})
        logger.info(f"Topic {topic_name} already exists")
        return topic_path
    except exceptions.NotFound:
        # Створення нового топіку
        try:
            topic = publisher.create_topic(request={"name": topic_path})
            logger.info(f"Created topic: {topic.name}")
            return topic_path
        except exceptions.AlreadyExists:
            # Топік був створений іншим процесом
            logger.info(f"Topic {topic_name} was created by another process")
            return topic_path
    except Exception as e:
        raise

def add_message_to_topic(message_data, topic_name=TOPIC_NAME):
    try:
        # Створення топіку, якщо не існує
        topic_path = ensure_topic_exists(topic_name)
        # Підготовка повідомлення
        message_json = json.dumps(message_data, ensure_ascii=False)
        message_bytes = message_json.encode('utf-8')
        # Додавання системних атрибутів
        attributes = {
            'timestamp': datetime.now(timezone.utc).isoformat(),
            'function_name': 'bookings',
            'project_id': project_id
        }
        # Публікація повідомлення
        future = publisher.publish(
            topic_path,
            data=message_bytes,
            **attributes
        )
        
        # Очікування результату
        message_id = future.result(timeout=30)
        logger.info(f"Message published to {topic_name} with ID: {message_id}")
        return message_id

    except json.JSONDecodeError as e:
        logger.error(f"JSON decode error: {e}")
        return None
    except Exception as e:
        logger.error(f"Error publishing message: {e}")
        return None
    
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
def apartments():
    if request.method == 'OPTIONS':
        return make_cors_response('', 204)
    
    user, error_resp = verify_token_via_cloud_function()
    if not user:
        return error_resp

    if request.method == 'POST':
        data = request.get_json()
        errors = validate_apartment(data)
        if errors:
            return make_cors_response(jsonify({"detail": " ".join(errors)}), 400)
        
        try:
            _, doc_ref = db.collection('apartments').add(data)
            message_id = add_message_to_topic({
                    'event': 'booking_created', 
                    'user_id': user.get("user"),
                    'apartment_id': doc_ref.id, 
                    'timestamp': datetime.now(timezone.utc).isoformat(),
                    "data": data
                })

            # Логування створення
            log_entry = {
                "user_id": user.get("user"),
                "role": "no_role" if not user.get("role") else user.get("role"),
                "action": "create_apartment",
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "details": {**data, 'id': doc_ref.id},
                "message_id": message_id
            }
            db.collection("logs").add(log_entry)
            return make_cors_response(jsonify({"status": "created"}), 201)

        except Exception as e:
            # Логування невдалої спроби
            db.collection('logs').add({
                "user_id": user.get("user"),
                "role": "no_role" if not user.get("role") else user.get("role"),
                "action": "create_apartment",
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "details": {**data, 'id': doc_ref.id},
                'status': 'fail',
                'error': str(e)
            })
            return make_cors_response(jsonify({'error': str(e)}), 409)

    elif request.method == 'GET':
        apartments = db.collection('apartments').stream()
        result = [{**doc.to_dict(), 'id': doc.id} for doc in apartments]
        return make_cors_response(jsonify(result), 200)
    
def main(request):
    with app.request_context(request.environ):
        return app.full_dispatch_request()