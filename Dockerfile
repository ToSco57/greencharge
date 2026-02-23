# --- STAGE 1: Builder ---
FROM golang:1.23-alpine AS builder
RUN apk add --no-cache git
RUN git clone https://github.com/teslamotors/vehicle-command.git /app
WORKDIR /app
RUN go install ./cmd/tesla-http-proxy
RUN go install ./cmd/tesla-control

# --- STAGE 2: Runtime ---
FROM alpine:latest
RUN apk add --no-cache ca-certificates openssl nginx python3 py3-flask py3-requests bash gettext

WORKDIR /app
COPY --from=builder /go/bin/tesla-http-proxy /usr/local/bin/
COPY --from=builder /go/bin/tesla-control /usr/local/bin/

# 1. MANAGER TELEMETRIA + BRIDGE CLI (Python)
RUN cat <<-'EOF' > /app/telemetry_manager.py
from flask import Flask, jsonify, request, send_from_directory
import datetime, os, subprocess

app = Flask(__name__)
data_store = {}

@app.route('/send-telemetry-command', methods=['POST'])
def send_telemetry_command():
    content = request.json
    vin = content.get('vin')
    token = request.headers.get('Authorization', '').replace('Bearer ', '')
    user_args = content.get('args', [])
    
    full_cmd = ['/usr/local/bin/tesla-control', '-vin', vin, '-ble=false'] + user_args
    env = os.environ.copy()
    env['TESLA_AUTH_TOKEN'] = token
    
    print(f"DEBUG EXEC: {' '.join(full_cmd)}") 
    
    try:
        res = subprocess.run(full_cmd, capture_output=True, text=True, timeout=20, env=env)
        return jsonify({
            'stdout': res.stdout, 
            'stderr': res.stderr, 
            'code': res.returncode,
            'cmd': ' '.join(full_cmd)
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/telemetrydata')
def get_data():
    vin = request.args.get('vin')
    if vin and vin in data_store:
        return jsonify(data_store[vin])
    return jsonify(data_store)

@app.route('/update-telemetry', methods=['POST'])
def update():
    content = request.json
    vin = content.get('vin') or content.get('device_id')
    if vin:
        if vin not in data_store: data_store[vin] = {}
        data_store[vin].update(content)
        data_store[vin]['last_update'] = datetime.datetime.now().isoformat()
    return "OK", 200

@app.route('/callback')
def callback():
    code = request.args.get('code')
    return f'<html><script>window.location.href="greencharge://auth?code={code}";</script></html>', 200

# ROTTE CRITICHE PER VALIDAZIONE TESLA
@app.route('/.well-known/appspecific/com.tesla.3p.json')
def serve_json():
    return send_from_directory('/var/www/html', 'tesla.json')

@app.route('/.well-known/appspecific/com.tesla.3p.public-key.pem')
def serve_public_key():
    return send_from_directory('/var/www/html', 'com.tesla.3p.public-key.pem')

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5000)
EOF

# 2. CONFIGURAZIONE NGINX
RUN echo 'server { \
    listen ${PORT}; \
    location ~* ^/(telemetrydata|update-telemetry|callback|.well-known|send-telemetry-command) { \
        proxy_pass http://127.0.0.1:5000; \
        proxy_set_header Host $host; \
    } \
    location / { \
        proxy_pass https://127.0.0.1:10001; \
        proxy_ssl_verify off; \
        proxy_http_version 1.1; \
        proxy_set_header Connection ""; \
        proxy_set_header Upgrade ""; \
        proxy_set_header Host $host; \
        proxy_set_header Authorization $http_authorization; \
        proxy_pass_header Authorization; \
        proxy_buffering off; \
    } \
}' > /etc/nginx/http.d/default.conf.template

# 3. START SCRIPT (Generazione chiavi e avvio)
RUN cat <<-'EOF' > /app/start.sh
#!/bin/bash
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout /app/tls.key -out /app/tls.crt -days 365 -subj '/CN=localhost'
mkdir -p /var/www/html
envsubst '${PORT}' < /etc/nginx/http.d/default.conf.template > /etc/nginx/http.d/default.conf

if [ -f /etc/secrets/public.pem ]; then
    # Genera JSON per validazione dominio
    PUB_KEY=$(grep -v '-' /etc/secrets/public.pem | tr -d '\n\r')
    echo "{\"domain\":\"gc-53r0.onrender.com\",\"public_key\":\"$PUB_KEY\"}" > /var/www/html/tesla.json
    
    # Copia PEM per validazione telemetria (Risolve il 404)
    cp /etc/secrets/public.pem /var/www/html/com.tesla.3p.public-key.pem
    
    echo "✅ Chiavi configurate correttamente."
else
    echo "❌ ATTENZIONE: /etc/secrets/public.pem non trovato!"
fi

nginx
python3 /app/telemetry_manager.py &
exec tesla-http-proxy -port 10001 -host 127.0.0.1 -key-file /etc/secrets/private.pem -tls-key /app/tls.key -cert /app/tls.crt -verbose
EOF

RUN chmod +x /app/start.sh
ENTRYPOINT ["/bin/bash", "/app/start.sh"]
