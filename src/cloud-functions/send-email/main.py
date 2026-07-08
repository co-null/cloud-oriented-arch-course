import os
import requests
import functions_framework
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry
from jinja2 import Environment, FileSystemLoader, select_autoescape

MAILGUN_API_KEY = os.environ.get("MAILGUN_API_KEY")
MAILGUN_DOMAIN = os.environ.get("MAILGUN_DOMAIN")
SENDER_EMAIL = f"noreply@{MAILGUN_DOMAIN}"

# HTTP-сесія з автоматичним retry — ініціалізується один раз при cold start
def _create_session() -> requests.Session:
    session = requests.Session()
    retry = Retry(
        total=3,
        backoff_factor=1, # Паузи між спробами: 1s, 2s, 4s
        status_forcelist=[429, 500, 502, 503, 504],
        allowed_methods=["POST"],
        raise_on_status=False
    )
    session.mount("https://", HTTPAdapter(max_retries=retry))
    return session

_http = _create_session()


# Ініціалізація Jinja2 — один раз при завантаженні модуля
_jinja_env = Environment(
    loader=FileSystemLoader(
        os.path.join(os.path.dirname(__file__), "templates")
    ),
    autoescape=select_autoescape(["html"])
)

def render_booking_email(data: dict) -> tuple:
    """Генерує (html, text) для підтвердження бронювання."""
    ctx = {
        "user_id":      data.get("user_id", "Шановний клієнте"),
        "booking_id":   data["booking_id"],
        "apartment_id": data["apartment_id"],
        "start_date":   data["start_date"],
        "end_date":     data["end_date"],
        "price":  data["price"]
    }
    html = _jinja_env.get_template("booking_created.html").render(**ctx)
    text = _jinja_env.get_template("booking_created.txt").render(**ctx)
    return html, text


@functions_framework.http
def send_email(request):
    headers = {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type',
    }

    if request.method == 'OPTIONS':
        # Preflight request
        return ('', 204, headers)

    # Маршрутизація за path — одна функція, два режими роботи
    path = request.path  # "/send-email" або "/send-booking-email"
    
    request_json = request.get_json(silent=True)
    if not request_json:
        return ({"status": "error", "message": "No JSON payload"}, 400, headers)

    if path == "/send-booking-email":
        # Шаблонний режим: caller передає структуровані дані бронювання
        required = ["booking_id", "apartment_id", "start_date",
                    "end_date", "price", "recipient"]
        missing = [f for f in required if f not in request_json]
        if missing:
            return ({"status": "error",
                     "message": f"Missing fields: {missing}"}, 400, headers)

        html, text = render_booking_email(request_json)
        request_json["text"] = text
        request_json["html"] = html
        request_json["subject"] = (
            request_json.get("subject") or
            f"✅ Бронювання {request_json['booking_id']} підтверджено"
        )

    # Спільна логіка відправки — для обох path
    recipient = request_json.get("recipient")
    subject   = request_json.get("subject", "Booking Confirmation")
    text      = request_json.get("text", "Your booking is confirmed!")
    html      = request_json.get("html") # Нове поле — опціональний HTML-варіант

    if not recipient:
        return ({"status": "error", "message": "Recipient email required"}, 400, headers)

    payload = {
        "from": SENDER_EMAIL, "to": [recipient],
        "subject": subject,   "text": text,
    }
    if html:
        payload["html"] = html  # Mailgun відправить multipart/alternative

    response = _http.post(
        f"https://api.mailgun.net/v3/{MAILGUN_DOMAIN}/messages",
        auth=("api", MAILGUN_API_KEY),
        data=payload,
    )

    if response.status_code == 200:
        mg_id = response.json().get("id", "unknown")
        print(f"[INFO] Email sent to={recipient} mg_id={mg_id}")
        return ({"status": "success", "message": "Email sent", "mailgun_id": mg_id},
                200, headers)

    elif response.status_code in (400, 401, 403):
        # Клієнтська помилка — retry не допоможе, повертаємо 400
        print(f"[ERROR] Mailgun client error {response.status_code}: {response.text[:200]}")
        return ({"status": "error", "message": response.text}, 400, headers)

    else:
        # Серверна помилка — caller може зробити retry, повертаємо 503
        print(f"[ERROR] Mailgun server error {response.status_code}: {response.text[:200]}")
        return ({"status": "error", "message": "Email provider unavailable"}, 503, headers)