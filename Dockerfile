# TELEMETRIA: Supporto VIN, Cadence e Configurazione Campi
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

# 1. MANAGER TELEMETRIA (Aggiornato per VIN e Cadence)
RUN printf 'from flask import Flask, jsonify, request, send_from_directory\n\
import datetime, os\n\
app = Flask(__name__)\n\
data_store = {}\n\
@app.route("/telemetrydata")\n\
def get_data():\n\
    vin = request.args.get("vin")\n\
    if vin and vin in data_store: return jsonify(data_store[vin])\n\
    return jsonify(data_store) if not vin else (jsonify({"error": "VIN not found"}), 404)\n\
@app.route("/update-telemetry", methods=["POST"])\n\
def update():\n\
    global data_store\n\
    content = request.json\n\
    if not content: return "No content", 400\n\
    vin = content.get("vin")\n\
    if not vin: return "Missing VIN", 400\n\
    if vin not in data_store:\n\
        data_store[vin] = {"battery_level": 0, "charge_current": 0, "charge_voltage": 0, "time_to_full": 0, "state": "offline", "cadence": 0, "last_update": None}\n\
    # Se arriva una configurazione (fields) o un dato reale, aggiorniamo\n\
    data_store[vin].update({\n\
        "battery_level": content.get("Soc", data_store[vin]["battery_level"]),\n\
        "charge_current": content.get("ChargerActualCurrent", data_store[vin]["charge_current"]),\n\
        "charge_voltage": content.get("ChargerVoltage", data_store[vin]["charge_voltage"]),\n\
        "time_to_full": content.get("MinutesToFullCharge", data_store[vin]["time_to_full"]),\n\
        "state": content.get("state", data_store[vin]["state"]),\n\
        "cadence": content.get("cadence", data_store[vin]["cadence"]),\n\
        "last_update": datetime.datetime.now().isoformat()\n\
    })\n\
    return "OK", 200\n\
@app.route("/.well-known/appspecific/com.tesla.3p.json")\n\
def serve_json(): return send_from_directory("/var/www/html", "tesla.json")\n\
@app.route("/callback")\n\
def callback():\n\
    code = request.args.get("code")\n\
    if code: return f"<html><script>window.location.href=\"greencharge://auth?code={code}\";</script></html>", 200\n\
    return "Missing code", 400\n\
if __name__ == "__main__":\n\
    app.run(host="127.0.0.1", port=5000)' > /app/telemetry_manager.py

# 2. CONFIGURAZIONE NGINX
RUN echo 'server { \
    listen ${PORT}; \
    \
    location ~* ^/(telemetrydata|update-telemetry|callback|.well-known) { \
        proxy_pass http://127.0.0.1:5000; \
        proxy_set_header Host $host; \
    } \
    \
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

# 3. START SCRIPT
RUN printf "#!/bin/bash\n\
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout /app/tls.key -out /app/tls.crt -days 365 -subj '/CN=localhost'\n\
mkdir -p /var/www/html\n\
envsubst '\${PORT}' < /etc/nginx/http.d/default.conf.template > /etc/nginx/http.d/default.conf\n\
if [ -f /etc/secrets/public.pem ]; then \n\
    PUB_KEY=\$(grep -v '-' /etc/secrets/public.pem | tr -d '\\\\n\\\\r'); \n\
    echo \"{\\\"domain\\\":\\\"gc-53r0.onrender.com\\\",\\\"public_key\\\":\\\"\$PUB_KEY\\\"}\" > /var/www/html/tesla.json; \n\
fi\n\
nginx\n\
python3 /app/telemetry_manager.py & \n\
exec tesla-http-proxy -port 10001 -host 127.0.0.1 -key-file /etc/secrets/private.pem -tls-key /app/tls.key -cert /app/tls.crt -verbose" > /app/start.sh && chmod +x /app/start.sh

ENTRYPOINT ["/bin/bash", "/app/start.sh"]
