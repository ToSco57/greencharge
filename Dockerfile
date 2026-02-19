FROM golang:1.23-alpine AS builder
RUN apk add --no-cache git
RUN git clone https://github.com/teslamotors/vehicle-command.git /app
WORKDIR /app
RUN go install ./cmd/tesla-http-proxy
RUN go install ./cmd/tesla-control

FROM alpine:latest
RUN apk add --no-cache ca-certificates openssl nginx python3 py3-flask py3-requests

WORKDIR /app

COPY --from=builder /go/bin/tesla-http-proxy /usr/local/bin/
COPY --from=builder /go/bin/tesla-control /usr/local/bin/

# 1. Script Python (Invariato)
RUN printf 'from flask import Flask, jsonify, request\n\
import datetime\n\
app = Flask(__name__)\n\
data_store = {"battery_level": 0, "charge_current": 0, "charge_voltage": 0, "time_to_full": 0, "state": "offline"}\n\
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
            "last_update": datetime.datetime.now().isoformat()\n\
        })\n\
    return "OK", 200\n\
if __name__ == "__main__":\n\
    app.run(host="0.0.0.0", port=5000)' > /app/telemetry.py

# 2. Script di avvio con FIX per l'autenticazione (Header forwarding)
RUN printf "#!/bin/sh\n\
echo \"server { \
    listen \${PORT}; \
    location /telemetrydata { proxy_pass http://127.0.0.1:5000/; } \
    location /update-telemetry { proxy_pass http://127.0.0.1:5000/update; } \
    location ^~ /.well-known/appspecific/ { alias /var/www/html/; } \
    location / { \
        proxy_pass https://127.0.0.1:10001; \
        proxy_ssl_verify off; \
        proxy_set_header Host \\\$host; \
        proxy_set_header Authorization \\\$http_authorization; \
        proxy_pass_header Authorization; \
    } \
}\" > /etc/nginx/http.d/default.conf\n\
\n\
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout /tmp/tls.key -out /tmp/tls.crt -days 365 -subj \"/CN=localhost\"\n\
mkdir -p /var/www/html\n\
if [ -f /etc/secrets/public.pem ]; then \
    PUB_KEY=\$(grep -v '-' /etc/secrets/public.pem | tr -d '\\\\n\\\\r'); \
    echo \"{\\\"domain\\\":\\\"gc-53r0.onrender.com\\\",\\\"public_key\\\":\\\"\$PUB_KEY\\\"}\" > /var/www/html/com.tesla.3p.json; \
    cp /etc/secrets/public.pem /var/www/html/com.tesla.3p.public-key.pem; \
fi\n\
nginx\n\
python3 /app/telemetry.py & \n\
exec tesla-http-proxy -port 10001 -host 127.0.0.1 -key-file /etc/secrets/private.pem -tls-key /tmp/tls.key -cert /tmp/tls.crt -verbose" > /app/start.sh && chmod +x /app/start.sh

ENV PORT=10000
EXPOSE 10000

ENTRYPOINT ["/bin/sh", "/app/start.sh"]
