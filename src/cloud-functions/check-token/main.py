import firebase_admin
from firebase_admin import credentials, auth
import functions_framework
from flask import jsonify
import requests

cred = credentials.ApplicationDefault()
firebase_admin.initialize_app(cred)

@functions_framework.http
def protected(request):
    headers = {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type',
    }

    auth_header = request.headers.get('Authorization', '')
    if not auth_header.startswith('Bearer '):
        return (jsonify({'error': 'No token provided'}), 401, headers)

    id_token = auth_header.split('Bearer ')[1]
    try:
        decoded_token = auth.verify_id_token(id_token)
        return (jsonify({
            'message': 'Access granted',
            'user': decoded_token.get('email'),
            'uid': decoded_token.get('uid')
        }), 200, headers)
    except Exception as e:
        return (jsonify({'error': 'Unauthorized', 'details': str(e)}), 401, headers)