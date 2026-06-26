from flask import Flask, request, jsonify, make_response
from datetime import datetime, timedelta, timezone
import os, requests, logging, json
from google.cloud import pubsub_v1
from google.api_core import exceptions
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

project_id = os.environ.get('GCP_PROJECT')
TOPIC_NAME = os.environ.get('PUBSUB_TOPIC')
PUBSUB_SUBSCRIPTION_NAME = os.environ.get('PUBSUB_SUBSCRIPTION')

# Ініціалізація Pub/Sub клієнтів
subscriber = pubsub_v1.SubscriberClient()

app = Flask(__name__)

def ensure_subscription_exists(topic_name, subscription_name = PUBSUB_SUBSCRIPTION_NAME):
    """Створює підписку, якщо вона не існує"""
    topic_path = f"projects/{project_id}/topics/{topic_name}"
    subscription_path = subscriber.subscription_path(project_id, subscription_name)
    
    try:
        # Перевірка існування підписки
        subscriber.get_subscription(request={"subscription": subscription_path})
        logger.info(f"Subscription {subscription_name} already exists")
        return subscription_path
    except exceptions.NotFound:
        # Створення нової підписки
        try:
            subscription = subscriber.create_subscription(
                request={
                    "name": subscription_path,
                    "topic": topic_path,
                    "ack_deadline_seconds": 60,
                    "message_retention_duration": {"seconds": 604800},  # 7 днів
                    "enable_message_ordering": False
                }
            )
            logger.info(f"Created subscription: {subscription.name}")
            return subscription_path
        except exceptions.AlreadyExists:
            logger.info(f"Subscription {subscription_name} was created by another process")
            return subscription_path
    except Exception as e:
        logger.error(f"Error ensuring subscription exists: {e}")
        raise

def get_recent_messages(topic_name, minutes=30):
    """
    Отримання повідомлень за останній період часу (30 хвилин за замовчуванням) з топіку Pub/Sub.
    """
     
    try:
        # Створення тимчасової підписки з фільтром за часом
        subscription_name = f"{topic_name}-recent-{datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S')}"
        subscription_path = ensure_subscription_exists(topic_name, subscription_name)
        
        # Розрахунок часового діапазону
        cutoff_time = datetime.now(timezone.utc) - timedelta(minutes=minutes)
        
        messages = []
        ack_ids = []
        
        # Отримання повідомлень з фільтрацією за часом
        response = subscriber.pull(
            request={
                "subscription": subscription_path,
                "max_messages": 100
            },
            timeout=10
        )
        
        for received_message in response.received_messages:
            message = received_message.message
            
            # Фільтрація за часом публікації
            if message.publish_time.replace(tzinfo=timezone.utc) >= cutoff_time:
                try:
                    message_data = json.loads(message.data.decode('utf-8'))
                except json.JSONDecodeError:
                    message_data = message.data.decode('utf-8')
                
                message_info = {
                    'message_id': message.message_id,
                    'data': message_data,
                    'attributes': dict(message.attributes),
                    'publish_time': message.publish_time.isoformat()
                }
                
                messages.append(message_info)
            
            ack_ids.append(received_message.ack_id)
        
        # Підтвердження всіх повідомлень
        if ack_ids:
            subscriber.acknowledge(
                request={
                    "subscription": subscription_path,
                    "ack_ids": ack_ids
                }
            )
        
        # Видалення тимчасової підписки
        try:
            subscriber.delete_subscription(request={"subscription": subscription_path})
        except Exception as e:
            logger.warning(f"Could not delete temporary subscription: {e}")
        
        response_data = {
            'success': True,
            'topic': topic_name,
            'time_range_minutes': minutes,
            'message_count': len(messages),
            'messages': messages,
            'timestamp': datetime.now(timezone.utc).isoformat()
        }
        
        return response_data
        
    except Exception as e:
        logger.error(f"Error in get_recent_messages: {e}")
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

@app.route('/', methods=['GET', 'OPTIONS'])
def messages():
    if request.method == 'OPTIONS':
        return make_cors_response('', 204)
    
    user, error_resp = verify_token_via_cloud_function()
    if not user:
        return error_resp
    
    if request.method == 'GET':
        result = get_recent_messages(topic_name=TOPIC_NAME)
        return make_cors_response(jsonify(result), 200)
    
def main(request):
    with app.request_context(request.environ):
        return app.full_dispatch_request()