import os
import requests
import functions_framework

MAILGUN_API_KEY = os.environ.get("MAILGUN_API_KEY")
MAILGUN_DOMAIN = os.environ.get("MAILGUN_DOMAIN")
SENDER_EMAIL = f"noreply@{MAILGUN_DOMAIN}"

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

    request_json = request.get_json(silent=True)
    if not request_json:
        return ({"status": "error", "message": "No JSON payload"}, 400, headers)

    recipient = request_json.get("recipient")
    subject = request_json.get("subject", "Booking Confirmation")
    text = request_json.get("text", "Your booking is confirmed!")

    if not recipient:
        return ({"status": "error", "message": "Recipient email required"}, 400, headers)

    response = requests.post(
        f"https://api.mailgun.net/v3/{MAILGUN_DOMAIN}/messages",
        auth=("api", MAILGUN_API_KEY),
        data={
            "from": SENDER_EMAIL,
            "to": [recipient],
            "subject": subject,
            "text": text,
        },
    )

    if response.status_code == 200:
        return ({"status": "success", "message": "Email sent"}, 200, headers)
    else:
        return ({
            "status": "error",
            "message": f"Failed to send email: {response.text}"
        }, 500, headers)