import firebase_admin
from firebase_admin import credentials, auth
from flask import Flask, request, jsonify

cred = credentials.ApplicationDefault()
firebase_admin.initialize_app(cred)

app = Flask(__name__)

@app.route('/protected', methods=['GET'])
def protected():
    auth_header = request.headers.get('Authorization', '')
    if not auth_header.startswith('Bearer '):
        return jsonify({'error': 'No token provided'}), 401

    id_token = auth_header.split('Bearer ')[1]
    try:
        decoded_token = auth.verify_id_token(id_token)
        return jsonify({
            'message': 'Access granted',
            'user': decoded_token.get('email'),
            'uid': decoded_token.get('uid')
        }), 200
    except Exception as e:
        return jsonify({'error': 'Unauthorized', 'details': str(e)}), 401