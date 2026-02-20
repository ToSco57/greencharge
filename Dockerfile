# TELEMETRIA: Fix Header Connection per Fleet API
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

# 1. MANAGER TELEMETRIA
RUN printf 'from flask import Flask, jsonify, request, send_from_directory\n\
import datetime, os\n\
app = Flask(__name__)\n\
data_store = {"battery_level": 0, "charge_current": 0, "charge_voltage": 0, "time_to_full": 0, "state": "offline", "last_update": None}\n\
@app.route("/telemetrydata")\n\
def get_data(): return jsonify(data_store)\n\
@app.route("/update-telemetry", methods=["POST"])\n\
def update():\n\
    content = request.json\n\
    if content: data_store.update({"battery_level": content.get("Soc", data_store["battery_level"]), "state": "online", "last_update": datetime.datetime.now().isoformat()})\n\
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

# 2. CONFIGURAZIONE NGINX (Rimosso Upgrade header per HTTP/2 compatibility)
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
        \
        # FIX PER HTTP/2: Rimuove header Connection/Upgrade che Tesla rifiuta \
        proxy_set_header Connection ""; \
        proxy_set_header Upgrade ""; \
        \
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
