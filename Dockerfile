# TELEMETRIA: Gestione diretta Proxy + Python (No Nginx)
FROM golang:1.23-alpine AS builder
RUN apk add --no-cache git
RUN git clone https://github.com/teslamotors/vehicle-command.git /app
WORKDIR /app
RUN go install ./cmd/tesla-http-proxy

FROM alpine:latest
RUN apk add --no-cache ca-certificates openssl python3 py3-flask py3-requests bash

WORKDIR /app

COPY --from=builder /go/bin/tesla-http-proxy /usr/local/bin/

# 1. MANAGER TELEMETRIA + GESTORE CHIAVI + CALLBACK
RUN printf 'from flask import Flask, jsonify, request, send_from_directory\n\
import datetime, os\n\
app = Flask(__name__)\n\
data_store = {"battery_level": 0, "charge_current": 0, "charge_voltage": 0, "time_to_full": 0, "state": "offline", "last_update": None}\n\
\n\
@app.route("/telemetrydata")\n\
def get_data(): return jsonify(data_store)\n\
\n\
@app.route("/update-telemetry", methods=["POST"])\n\
def update():\n\
    content = request.json\n\
    if content:\n\
        data_store.update({\n\
            "battery_level": content.get("Soc", data_store["battery_level"]),\n\
            "charge_current": content.get("ChargerActualCurrent", data_store["charge_current"]),\n\
            "charge_voltage": content.get("ChargerVoltage", data_store["charge_voltage"]),\n\
            "time_to_full": content.get("MinutesToFullCharge", data_store["time_to_full"]),\n\
            "state": "online", "last_update": datetime.datetime.now().isoformat()\n\
        })\n\
    return "OK", 200\n\
\n\
@app.route("/.well-known/appspecific/com.tesla.3p.json")\n\
def serve_json(): return send_from_directory("/var/www/html", "tesla.json")\n\
\n\
@app.route("/.well-known/appspecific/com.tesla.3p.public-key.pem")\n\
def serve_pem(): return send_from_directory("/var/www/html", "com.tesla.3p.public-key.pem")\n\
\n\
@app.route("/callback")\n\
def callback():\n\
    code = request.args.get("code")\n\
    if code: return f"<html><script>window.location.href=\"greencharge://auth?code={code}\";</script></html>", 200\n\
    return "Codice non trovato", 400\n\
\n\
if __name__ == "__main__":\n\
    app.run(host="0.0.0.0", port=5000)' > /app/telemetry_manager.py

# 2. SCRIPT DI AVVIO (start.sh)
RUN printf "#!/bin/sh\n\
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout /app/tls.key -out /app/tls.crt -days 365 -subj '/CN=localhost'\n\
mkdir -p /var/www/html\n\
if [ -f /etc/secrets/public.pem ]; then \n\
    PUB_KEY=\$(grep -v '-' /etc/secrets/public.pem | tr -d '\\\\n\\\\r'); \n\
    echo \"{\\\"domain\\\":\\\"gc-53r0.onrender.com\\\",\\\"public_key\\\":\\\"\$PUB_KEY\\\"}\" > /var/www/html/tesla.json; \n\
    cp /etc/secrets/public.pem /var/www/html/com.tesla.3p.public-key.pem; \n\
fi\n\
# Avvio Flask in background (Porta 5000)\n\
python3 /app/telemetry_manager.py & \n\
# Avvio Proxy Tesla (Porta \$PORT assegnata da Render)\n\
# Il proxy agira come server principale\n\
exec tesla-http-proxy -port \$PORT -key-file /etc/secrets/private.pem -tls-key /app/tls.key -cert /app/tls.crt -verbose" > /app/start.sh && chmod +x /app/start.sh

EXPOSE 10000
ENTRYPOINT ["/bin/sh", "/app/start.sh"]
