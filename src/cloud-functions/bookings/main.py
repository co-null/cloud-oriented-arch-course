from flask import Flask, request, jsonify, make_response
import firebase_admin
from firebase_admin import credentials, firestore
from datetime import datetime, timedelta, timezone
import os, requests, logging, uuid, json
from google.cloud import pubsub_v1
from google.api_core import exceptions


logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Вичитаємо env variables
project_id = os.environ.get('GCP_PROJECT')
TOPIC_NAME = os.environ.get('PUBSUB_TOPIC')

# Ініціалізація Firestore
if not firebase_admin._apps:
    try:
        # Використовуємо Application Default Credentials
        cred = credentials.ApplicationDefault()
        firebase_admin.initialize_app(cred, {
            'projectId': project_id
        })
        logger.info("Firebase Admin SDK initialized successfully")
    except Exception as e:
        logger.error(f"Failed to initialize Firebase Admin SDK: {e}")
        raise

try:
    db = firestore.client()
    logger.info("Firestore client initialized successfully")
except Exception as e:
    logger.error(f"Failed to initialize Firestore client: {e}")
    raise

# Ініціалізація Pub/Sub клієнтів
try:
    publisher = pubsub_v1.PublisherClient()
    logger.info("Pub/Sub publisher initialized successfully")
except Exception as e:
    logger.error(f"Failed to initialize Pub/Sub publisher: {e}")
    raise


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

def _safe_serialize(data: dict) -> dict:
        """
        Перетворює всі Firestore-специфічні типи на JSON-сумісні.
        Викликається для кожного документа перед jsonify().
        """
        result = {}
        for key, val in data.items():
            if val is None:
                result[key] = None
            elif hasattr(val, 'isoformat'):
                # DatetimeWithNanoseconds → ISO string
                result[key] = val.isoformat()
            elif hasattr(val, '_seconds'):
                # Firestore Timestamp (старіший формат)
                result[key] = datetime.fromtimestamp(
                    val._seconds, tz=timezone.utc
                ).isoformat()
            else:
                result[key] = val
        return result

@app.route('/', methods=['POST', 'GET', 'OPTIONS'])
def bookings():
    """Основна функція для роботи з бронюваннями"""
    if request.method == 'OPTIONS':
        return make_cors_response('', 204)
    
    # Перевірка токена
    user, error_resp = verify_token_via_cloud_function()
    if not user:
        return error_resp
    
    user_id = user.get("user")
    logger.info(f"Processing request for user: {user_id}")

    if request.method == 'POST':
        return create_booking(user_id)
    elif request.method == 'GET':
        return get_bookings(user_id)

def create_booking(user_id):
    """Створення нового бронювання"""   
    try:
        errors = []
        data = request.get_json()

        if not data:
            return make_cors_response(jsonify({"detail": "Відсутні дані"}), 400)
        
        apartment_id = data.get('apartment_id')
        start_date = data.get('start_date')
        end_date = data.get('end_date')

        # Створюємо новий документ з унікальним ID
        booking_id     = str(uuid.uuid4())
        correlation_id = str(uuid.uuid4())  # генеруємо ОДИН РАЗ

        booking_data = {
                'booking_id':     booking_id,
                'correlation_id': correlation_id,  # зберігаємо для майбутніх запитів
                'status':         'processing',
                'current_step':   'BOOKING_RECEIVED',
                'created_at':     firestore.SERVER_TIMESTAMP,
                'updated_at':     firestore.SERVER_TIMESTAMP,
                'user_id':        user_id,
                'apartment_id':   apartment_id,
                'start_date':     start_date,
                'end_date':       end_date,
            }

        # Валідація обов’язкових полів
        if not all([apartment_id, start_date, end_date]):
            errors.append("Всі поля обов’язкові")

        # Валідація дат
        if start_date >= end_date:
            errors.append("Дата початку має бути меншою за дату завершення")

        # Перевірка apartment_id
        try:
            apartment_ref = db.collection('apartments').document(apartment_id)
            apartment_doc = apartment_ref.get()
            if not apartment_doc.exists:
                errors.append("Квартира не знайдена")
        except Exception as e:
            logger.error(f"Error checking apartment: {e}")
            errors.append("Помилка перевірки квартири")

        booking_data = {**booking_data,
                'owner_email':    apartment_doc.get('user_id'),
                'address':        apartment_doc.get('address'),
                'description':    apartment_doc.get('description'),
                'rooms':          apartment_doc.get('rooms'),
                'price':          apartment_doc.get('price')
            }

        if errors:
            return make_cors_response(jsonify({"detail": " ".join(errors)}), 400)
        
        # Транзакція для перевірки конфлікту та створення бронювання
        @firestore.transactional
        def transaction_func(transaction):
            bookings_ref = db.collection('bookings')
            conflict_query = bookings_ref.where('apartment_id', '==', apartment_id)\
                .where('start_date', '<=', end_date)\
                .where('end_date', '>=', start_date)\
                .limit(1)
            conflict = [doc for doc in conflict_query.stream(transaction=transaction)]
            if conflict:
                raise Exception('Квартира вже заброньована на ці дати')
            
            doc_ref = bookings_ref.document(booking_id)
            transaction.set(doc_ref, booking_data)
            return booking_id, booking_data
        
        try:
            transaction = db.transaction()
            booking_id, booking_data = transaction_func(transaction)

            # Публікація події в Pub/Sub
            ## Публікуємо подію з correlation_id
            event_id       = str(uuid.uuid4())
            booking_data['event_id'] = event_id  # додаємо event_id до даних бронювання
            booking_data['event_type'] = 'booking_created'
            booking_data['version'] = '1.0'
            booking_data['causation_id'] = None  # перша подія, немає причини
            booking_data['source'] = 'bookings_api'

            message_id = add_message_to_topic(booking_data)

            # Логування успішної спроби
            try:
                db.collection('booking_logs').add({**booking_data,
                    'status': 'success',
                    'message_id': message_id,
                    'timestamp': datetime.now(timezone.utc).isoformat()
                })
            except Exception as e:
                logger.error(f"Error logging booking: {e}")

            return make_cors_response(jsonify({'message': 'Бронювання створено'}), 201)
        
        except Exception as e:
            logger.error(f"Error creating booking: {e}")
            # Логування невдалої спроби
            try:
                db.collection('booking_logs').add({**booking_data,
                    'status': 'fail',
                    'error': str(e),
                    'timestamp': datetime.now(timezone.utc).isoformat()
                })
            except Exception as log_error:
                logger.error(f"Error logging failed booking: {log_error}")

            return make_cors_response(jsonify({'error': str(e)}), 409)
        
    except Exception as e:
        logger.error(f"Unexpected error in create_booking: {e}")
        return make_cors_response(jsonify({'error': 'Внутрішня помилка сервера'}), 500)

def get_bookings(user_id):
    """Отримання бронювань користувача"""
    try:
        bookings_ref = db.collection('bookings')
        bookings_query = (
            bookings_ref
            .where('user_id', '==', user_id)
            .order_by('created_at', direction=firestore.Query.DESCENDING)
        )
        docs   = bookings_query.stream()
        result = []
        for doc in docs:
            data = _safe_serialize(doc.to_dict())

            # ── Нормалізуємо Firestore Timestamp → ISO string ──────────────
            # doc.to_dict() повертає DatetimeWithNanoseconds,
            # який jsonify() не вміє серіалізувати
            for field in ('created_at', 'updated_at'):
                val = data.get(field)
                if val is not None and hasattr(val, 'isoformat'):
                    data[field] = val.isoformat()
                elif val is None:
                    data[field] = ''
                data['booking_id'] = doc.id  # додаємо booking_id для фронтенду

            result.append(data)
        logger.info(f"Found {len(result)} bookings for user_id={user_id}")

        # ── Повертаємо об'єкт з полем bookings ────────────────────────────
        # Фронтенд очікує { "bookings": [...] }
        return make_cors_response(jsonify({"bookings": result}), 200)


    except Exception as e:
        logger.error(f"Error getting bookings: {e}")
        return make_cors_response(jsonify({'error': 'Помилка отримання бронювань'}), 500)


def main(request):
    """Головна функція для Cloud Functions"""
    try:
        with app.request_context(request.environ):
            return app.full_dispatch_request()
    except Exception as e:
        logger.error(f"Error in main function: {e}")
        return make_cors_response(jsonify({'error': 'Внутрішня помилка сервера'}), 500)