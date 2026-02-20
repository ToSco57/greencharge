# TELEMETRIA INTEGRATA - Versione con Tunneling Header Garantito
FROM golang:1.23-alpine AS builder
RUN apk add --no-cache git
RUN git clone https://github.com/teslamotors/vehicle-command.git /app
WORKDIR /app
RUN go install ./cmd/tesla-http-proxy
RUN go install ./cmd/tesla-control

FROM alpine:latest
RUN apk add --no-cache ca-certificates openssl nginx python3 py3-flask py3-requests bash gettext

WORKDIR /app

COPY --from=builder /go/bin/tesla-http-proxy /usr/local/bin/
COPY --from=builder /go/bin/tesla-control /usr/local/bin/

# TELEMETRIA: Script Manager (RAM)
RUN printf 'from flask import Flask, jsonify, request\n\
import datetime\n\
app = Flask(__name__)\n\
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

# TELEMETRIA: Configurazione Nginx (FIX TOTALE OAUTH)
RUN echo 'server { \
    listen ${PORT}; \
    \
    # Disabilita restrizioni sui nomi degli header \
    underscores_in_headers on; \
    pass_header Authorization; \
    \
    location ^~ /.well-known/appspecific/com.tesla.3p.json { \
        alias /var/www/html/tesla.json; \
        add_header Content-Type application/json; \
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
        # Usiamo localhost esplicito per evitare problemi di risoluzione \
        proxy_pass https://localhost:10001; \
        proxy_ssl_verify off; \
        \
        # FORZATURA HEADER: Nginx deve passare tutto "as is" \
        proxy_set_header Host $host; \
        proxy_set_header X-Real-IP $remote_addr; \
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; \
        proxy_set_header X-Forwarded-Proto $scheme; \
        \
        # Passaggio del Token Bearer \
        proxy_set_header Authorization $http_authorization; \
        proxy_pass_request_headers on; \
        \
        # Evita timeout durante i comandi lunghi \
        proxy_connect_timeout 90; \
        proxy_send_timeout 90; \
        proxy_read_timeout 90; \
    } \
}' > /etc/nginx/http.d/default.conf.template

# Script Entrypoint
RUN printf '#!/bin/bash\n\
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout /app/tls.key -out /app/tls.crt -days 365 -subj "/CN=localhost"\n\
mkdir -p /var/www/html\n\
envsubst "\${PORT}" < /etc/nginx/http.d/default.conf.template > /etc/nginx/http.d/default.conf\n\
if [ -f /etc/secrets/public.pem ]; then \
    PUB_KEY=$(grep -v "-" /etc/secrets/public.pem | tr -d "\\n\\r"); \
    echo "{\\\"domain\\\":\\\"gc-53r0.onrender.com\\\",\\\"public_key\\\":\\\"$PUB_KEY\\\"}" > /var/www/html/tesla.json; \
    cp /etc/secrets/public.pem /var/www/html/com.tesla.3p.public-key.pem; \
fi\n\
nginx\n\
python3 /app/telemetry_manager.py & \n\
while [ ! -f /app/tls.crt ]; do sleep 1; done\n\
# Ascolta su localhost (127.0.0.1) per sicurezza interna \
exec tesla-http-proxy -port 10001 -host 127.0.0.1 -key-file /etc/secrets/private.pem -tls-key /app/tls.key -cert /app/tls.crt -verbose\n' > /app/entrypoint.sh && chmod +x /app/entrypoint.sh

EXPOSE 10000
ENTRYPOINT ["/app/entrypoint.sh"]
