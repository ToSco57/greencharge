# TELEMETRIA INTEGRATA - Gestione stato in RAM e proxy Tesla
FROM golang:1.23-alpine AS builder
RUN apk add --no-cache git
RUN git clone https://github.com/teslamotors/vehicle-command.git /app
WORKDIR /app
RUN go install ./cmd/tesla-http-proxy
# Installiamo anche tesla-control per poter inviare comandi di config telemetria
RUN go install ./cmd/tesla-control

FROM alpine:latest
# Aggiungiamo python3 e flask per gestire lo stato in RAM
RUN apk add --no-cache ca-certificates openssl nginx python3 py3-flask py3-requests bash

WORKDIR /app

COPY --from=builder /go/bin/tesla-http-proxy /usr/local/bin/
COPY --from=builder /go/bin/tesla-control /usr/local/bin/

# 1. SCRIPT PYTHON MANAGER (Stato in RAM)
RUN printf 'from flask import Flask, jsonify, request\n\
import datetime\n\
app = Flask(__name__)\n\
# Stato iniziale\n\
data_store = {"battery_level": 0, "charge_current": 0, "charge_voltage": 0, "time_to_full": 0, "state": "offline", "last_update": None}\n\
@app.route("/")\n\
def get_data(): return jsonify(data_store)\n\
@app.route("/update", methods=["POST"])\n\
def update():\n\
    content = request.json\n\
    if content:\n\
        data_store.update({\n\
            "battery_level": content.get("Soc", data_store["battery_level"]),\n\
            "charge_current": content.get("ChargerActualCurrent", data_store["charge_current"]),\n\
            "charge_voltage": content.get("ChargerVoltage", data_store["charge_voltage"]),\n\
            "time_to_full": content.get("MinutesToFullCharge", data_store["time_to_full"]),\n\
            "state": "online",\n\
            "last_update": datetime.datetime.now().isoformat()\n\
        })\n\
    return "OK", 200\n\
if __name__ == "__main__":\n\
    app.run(host="127.0.0.1", port=5000)' > /app/telemetry_manager.py

# 2. CONFIGURAZIONE NGINX AGGIORNATA
# Porta dinamica ${PORT} per Render, proxy_pass per telemetria e fix per Authorization
RUN echo 'server { \
    listen ${PORT}; \
    location ^~ /.well-known/appspecific/com.tesla.3p.json { \
        alias /var/www/html/tesla.json; \
        add_header Content-Type application/json; \
        add_header Access-Control-Allow-Origin *; \
    } \
    location ^~ /.well-known/appspecific/com.tesla.3p.public-key.pem { \
        alias /var/www/html/com.tesla.3p.public-key.pem; \
        add_header Content-Type text/plain; \
    } \
    location /telemetrydata { \
        proxy_pass http://127.0.0.1:5000/; \
    } \
    location /update-telemetry { \
        proxy_pass http://127.0.0.1:5000/update; \
    } \
    location / { \
        proxy_pass https://127.0.0.1:10001; \
        proxy_ssl_verify off; \
        proxy_set_header Host $host; \
        proxy_set_header X-Real-IP $remote_addr; \
        proxy_set_header Authorization $http_authorization; \
        proxy_pass_header Authorization; \
    } \
}' > /etc/nginx/http.d/default.conf.template

EXPOSE 10000

# 3. CMD DI AVVIO
CMD ["sh", "-c", "openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout /tmp/tls.key -out /tmp/tls.crt -days 365 -subj '/CN=localhost' && \
mkdir -p /var/www/html && \
# Inserimento porta Render \
envsubst '${PORT}' < /etc/nginx/http.d/default.conf.template > /etc/nginx/http.d/default.conf && \
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
