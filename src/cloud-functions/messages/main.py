from datetime import datetime, timedelta, timezone
import os, requests, logging, json
from google.cloud import pubsub_v1
from google.api_core import exceptions

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

project_id = os.environ.get('GCP_PROJECT')
TOPIC_NAME = os.environ.get('PUBSUB_TOPIC')
PUBSUB_SUBSCRIPTION_NAME = os.environ.get('PUBSUB_SUBSCRIPTION')

# Ініціалізація Pub/Sub клієнтів
subscriber = pubsub_v1.SubscriberClient()

CORS_HEADERS = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    'Access-Control-Allow-Headers': 'Authorization,Content-Type',
    'Access-Control-Max-Age': '3600',
}


def make_cors_response(body='', status=200, headers=None):
    response_headers = {**CORS_HEADERS}
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


def ensure_subscription_exists(topic_name, subscription_name=PUBSUB_SUBSCRIPTION_NAME):
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
        if not topic_name:
            raise ValueError("Topic name is required")

        # Використання основної підписки
        subscription_path = ensure_subscription_exists(topic_name)

        # Розрахунок часового діапазону
        cutoff_time = datetime.now(timezone.utc) - timedelta(minutes=minutes)
        logger.info(f"Looking for messages after {cutoff_time}")

        messages = []
        ack_ids = []

        # Отримання повідомлень
        try:
            response = subscriber.pull(
                request={
                    "subscription": subscription_path,
                    "max_messages": 100
                },
                timeout=10
            )

            logger.info(f"Pulled {len(response.received_messages)} messages from subscription")
            for received_message in response.received_messages:
                message = received_message.message

                # Конвертація publish_time до UTC якщо потрібно
                publish_time = message.publish_time
                if publish_time.tzinfo is None:
                    publish_time = publish_time.replace(tzinfo=timezone.utc)

                # Фільтрація за часом публікації
                if publish_time >= cutoff_time:
                    try:
                        # Спроба декодувати JSON
                        message_data = json.loads(message.data.decode('utf-8'))
                    except json.JSONDecodeError:
                        # Якщо не JSON, зберігаємо як текст
                        message_data = message.data.decode('utf-8')
                    except UnicodeDecodeError:
                        # Якщо не можемо декодувати як UTF-8
                        message_data = str(message.data)

                    message_info = {
                        'message_id': message.message_id,
                        'data': message_data,
                        'attributes': dict(message.attributes),
                        'publish_time': publish_time.isoformat()
                    }

                    messages.append(message_info)
                    logger.info(f"Added message {message.message_id} published at {publish_time}")

                else:
                    logger.info(f"Skipping old message {message.message_id} published at {publish_time}")

                # Збираємо всі ack_ids для підтвердження
                ack_ids.append(received_message.ack_id)

            # Підтвердження всіх повідомлень (навіть тих, що не пройшли фільтр)
            if ack_ids:
                subscriber.acknowledge(
                    request={
                        "subscription": subscription_path,
                        "ack_ids": ack_ids
                    }
                )
                logger.info(f"Acknowledged {len(ack_ids)} messages")

        except Exception as e:
            logger.error(f"Error pulling messages: {e}")
            raise

        response_data = {
            'success': True,
            'topic': topic_name,
            'time_range_minutes': minutes,
            'message_count': len(messages),
            'messages': messages,
            'timestamp': datetime.now(timezone.utc).isoformat()
        }

        logger.info(f"Returning {len(messages)} recent messages")
        return response_data

    except Exception as e:
        logger.error(f"Error in get_recent_messages: {e}")
        return {
            'success': False,
            'error': str(e),
            'topic': topic_name,
            'time_range_minutes': minutes,
            'message_count': 0,
            'messages': [],
            'timestamp': datetime.now(timezone.utc).isoformat()
        }


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

    if request.method == 'OPTIONS':
        return make_cors_response('', 204)

    user, error_resp = verify_token_via_cloud_function(request)
    if not user:
        return error_resp

    if request.method == 'GET':
        result = get_recent_messages(topic_name=TOPIC_NAME)
        if result.get('success'):
            return json_response(result, 200)
        else:
            return json_response(result, 500)

    return json_response({"detail": "Метод не підтримується"}, 405)