"""
Python code with various errors and vulnerabilities for scanner testing
WARNING: This code contains intentional security issues - DO NOT use in production!
"""

import os
import pickle
import sqlite3
from flask import Flask, request

app = Flask(__name__)

# VULNERABILITY 1: Hardcoded credentials
DATABASE_PASSWORD = "admin123"
API_KEY = "sk-1234567890abcdef"
DB_USERNAME = "root"
DB_PASSWORD = "P@ssw0rd123"
AWS_ACCESS_KEY = "AKIAIOSFODNN7EXAMPLE"
AWS_SECRET_KEY = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
SMTP_PASSWORD = "mail_pass_2024"
JWT_SECRET = "my_super_secret_jwt_key_12345"

# VULNERABILITY 2: SQL Injection
def get_user_data(username):
    conn = sqlite3.connect('users.db')
    cursor = conn.cursor()
    print("abcd")
    # Vulnerable to SQL injection
    query = f"SELECT * FROM users WHERE username = '{username}'"
    cursor.execute(query)
    return cursor.fetchall()

# VULNERABILITY 2b: Database connection with cleartext credentials
def connect_to_database():
    import pymysql
    connection = pymysql.connect(
        host='db.example.com',
        user='admin',
        password='SuperSecret123!',
        database='production_db'
    )
    return connection

# VULNERABILITY 2c: Connection string with credentials
CONNECTION_STRING = "postgresql://dbuser:MyPassword456@localhost:5432/mydb"
MONGO_URI = "mongodb://mongouser:mongo123@mongodb0.example.com:27017/admin"

# VULNERABILITY 3: Command Injection
def ping_server(hostname):
    # Vulnerable to command injection
    os.system(f"ping -c 4 {hostname}")

# VULNERABILITY 4: Path Traversal
@app.route('/read_file')
def read_file():
    filename = request.args.get('file')
    # Vulnerable to path traversal
    with open(filename, 'r') as f:
        return f.read()

# VULNERABILITY 5: Insecure Deserialization
def load_user_session(session_data):
    # Unsafe pickle usage
    return pickle.loads(session_data)

# VULNERABILITY 6: Weak cryptography
def encrypt_password(password):
    # Using weak MD5 hash
    import hashlib
    return hashlib.md5(password.encode()).hexdigest()

# ERROR 7: Syntax Error (missing colon)
def broken_function():
    return "This will cause a syntax error"

# ERROR 8: Undefined variable
def use_undefined_var():
    print(undefined_variable)

# ERROR 9: Type Error
def add_numbers():
    result = "5" + 10
    return result

# ERROR 10: Division by zero
def divide():
    x = 10
    y = 0
    return x / y

# ERROR 11: Index out of range
def access_list():
    my_list = [1, 2, 3]
    return my_list[10]

# VULNERABILITY 12: XXE (XML External Entity)
def parse_xml(xml_string):
    import xml.etree.ElementTree as ET
    # Vulnerable to XXE attacks
    root = ET.fromstring(xml_string)
    return root

# VULNERABILITY 13: SSRF (Server-Side Request Forgery)
@app.route('/fetch_url')
def fetch_url():
    import requests
    url = request.args.get('url')
    # Vulnerable to SSRF
    response = requests.get(url)
    return response.text

# VULNERABILITY 13b: API keys in code
GITHUB_TOKEN = "ghp_1234567890abcdefghijklmnopqrstuvwxyz"
SLACK_WEBHOOK = "https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXX"
STRIPE_API_KEY = "sk_live_51A1b2C3d4E5f6G7h8I9j0K1L2M3N4O5P6Q7R8S9T0"
OPENAI_API_KEY = "sk-proj-abcdefghijklmnopqrstuvwxyz1234567890ABCDEFGHIJK"



# ERROR 14: Improper exception handling
def risky_operation():
    try:
        dangerous_function()
    except:
        pass  # Silently catching all exceptions

# VULNERABILITY 15: Insecure random number generation
def generate_token():
    import random
    # Using weak random for security-sensitive operation
    return random.randint(1000, 9999)


global_list = []
def memory_leak():
    global global_list
    global_list.append([0] * 10000000)


if __name__ == '__main__':
    # Running Flask in debug mode in production
    app.run(debug=True, host='0.0.0.0')