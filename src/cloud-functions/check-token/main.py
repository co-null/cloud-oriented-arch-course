import firebase_admin, os
from firebase_admin import credentials, auth
import functions_framework
from flask import jsonify, request
import logging

cred = credentials.ApplicationDefault()
firebase_admin.initialize_app(cred, {
    'projectId': os.environ.get('GCP_PROJECT') or os.environ.get('GOOGLE_CLOUD_PROJECT') or 'cloud-oriented-arch-course'
})
firebase_admin.initialize_app(cred)

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
        return (jsonify({'error': 'No token provided'}), 401, headers)

    id_token = auth_header.split('Bearer ')[1]
    try:
        decoded_token = auth.verify_id_token(id_token)
        logging.info(f"Decoded token: {decoded_token}")
        return (jsonify({
            'message': 'Access granted',
            'user': decoded_token.get('email'),
            'uid': decoded_token.get('uid')
        }), 200, headers)
    except Exception as e:
        logging.error(f"Token verification error: {str(e)}")
        return (jsonify({'error': 'Unauthorized', 'details': str(e)}), 401, headers)