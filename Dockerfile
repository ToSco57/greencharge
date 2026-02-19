# docker con telemetria
FROM golang:1.23-alpine AS builder
RUN apk add --no-cache git
RUN git clone https://github.com/teslamotors/vehicle-command.git /app
WORKDIR /app
RUN go install ./cmd/tesla-http-proxy
RUN go install ./cmd/tesla-control

FROM alpine:latest
# Installiamo python e websocket-client per gestire il flusso dati
RUN apk add --no-cache ca-certificates openssl nginx python3 py3-flask py3-requests py3-websocket-client

COPY --from=builder /go/bin/tesla-http-proxy /usr/local/bin/
COPY --from=builder /go/bin/tesla-control /usr/local/bin/

# Configurazione Nginx
RUN echo 'server { \
    listen 10000; \
    location ^~ /.well-known/appspecific/com.tesla.3p.json { \
        alias /var/www/html/tesla.json; \
        add_header Content-Type application/json; \
        add_header Access-Control-Allow-Origin *; \
    } \
    location ^~ /.well-known/appspecific/com.tesla.3p.public-key.pem { \
        alias /var/www/html/com.tesla.3p.public-key.pem; \
        add_header Content-Type text/plain; \
    } \
    location /callback { \
        if ($arg_code) { \
            return 302 greencharge://auth?code=$arg_code; \
        } \
        return 200 "Codice non trovato"; \
    } \
    location /telemetrydata { \
        proxy_pass http://127.0.0.1:5000/; \
    } \
    location / { \
        proxy_pass https://127.0.0.1:10001; \
        proxy_ssl_verify off; \
        proxy_set_header Host $host; \
        proxy_set_header X-Real-IP $remote_addr; \
    } \
}' > /etc/nginx/http.d/default.conf

# Script Python Manager con i campi richiesti
RUN echo 'from flask import Flask, jsonify\n\
import threading, json, time\n\
app = Flask(__name__)\n\
# Stato iniziale in RAM\n\
data_store = {\n\
    "battery_level": None,\n\
    "charge_current": 0,\n\
    "charge_voltage": 0,\n\
    "time_to_full": 0,\n\
    "vehicle_state": "unknown",\n\
    "last_update": None\n\
}\n\
@app.route("/")\n\
def get_data(): return jsonify(data_store)\n\
\n\
def mock_telemetry_loop():\n\
    # Qui andrebbe la logica websocket reale verso Tesla\n\
    # Per ora inizializziamo la struttura\n\
    while True:\n\
        time.sleep(10)\n\
\n\
threading.Thread(target=mock_telemetry_loop, daemon=True).start()\n\
if __name__ == "__main__":\n\
    app.run(port=5000)' > /app/telemetry_manager.py

EXPOSE 10000

CMD ["sh", "-c", "openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout /tmp/tls.key -out /tmp/tls.crt -days 365 -subj '/CN=localhost' && \
    mkdir -p /var/www/html && \
    if [ -f /etc/secrets/public.pem ]; then \
        PUB_KEY=$(grep -v '^-' /etc/secrets/public.pem | tr -d '\n\r'); \
        echo \"{\\\"domain\\\":\\\"gc-53r0.onrender.com\\\",\\\"public_key\\\":\\\"$PUB_KEY\\\"}\" > /var/www/html/tesla.json; \
        cp /etc/secrets/public.pem /var/www/html/com.tesla.3p.public-key.pem; \
        chmod 644 /var/www/html/tesla.json /var/www/html/com.tesla.3p.public-key.pem; \
    else \
        echo '{\"error\":\"file public.pem missing\"}' > /var/www/html/tesla.json; \
    fi && \
    nginx && \
    python3 /app/telemetry_manager.py & \
    tesla-http-proxy -port 10001 -host 127.0.0.1 -key-file /etc/secrets/private.pem -tls-key /tmp/tls.key -cert /tmp/tls.crt -verbose"]
