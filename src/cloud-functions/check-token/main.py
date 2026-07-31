import firebase_admin
from firebase_admin import credentials, auth
import functions_framework
import logging, json

cred = credentials.ApplicationDefault()
firebase_admin.initialize_app(cred, {
    'projectId': 'cloud-oriented-arch-course'  # Replace with your actual project ID
})

def make_json_response(payload, status_code, cors_headers):
    headers = {
        **cors_headers,
        'Content-Type': 'application/json',
    }

    return (
        json.dumps(payload),
        status_code,
        headers,
    )

@functions_framework.http
def protected(request):
    headers = {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Authorization, Content-Type',
    }

    if request.method == 'OPTIONS':
        # Preflight request
        return ('', 204, headers)

    auth_header = request.headers.get('Authorization', '')
    logging.info(f"Authorization header: {auth_header}")
    if not auth_header.startswith('Bearer '):
        logging.error("No Bearer token")
        return make_json_response({'error': 'No token provided'}, 401, headers)

    id_token = auth_header.split('Bearer ')[1]
    try:
        decoded_token = auth.verify_id_token(id_token)
        logging.info(f"Decoded token: {decoded_token}")
        return (make_json_response({
            'message': 'Access granted',
            'user': decoded_token.get('email'),
            'uid': decoded_token.get('uid')
        }), 200, headers)
    except Exception as e:
        logging.error(f"Token verification error: {str(e)}")
        return (make_json_response({'error': 'Unauthorized', 'details': str(e)}), 401, headers)