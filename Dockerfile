#Version 1.0 Gestione comandi firmati e chiavi per teslaproxy
#Version 1.1 - Aggiunto controllo SECURE_KEY tramite Nginx

# --- STAGE 1: Builder ---
FROM golang:1.23-alpine AS builder
RUN apk add --no-cache git
RUN git clone https://github.com/teslamotors/vehicle-command.git /app
WORKDIR /app
RUN go install ./cmd/tesla-http-proxy

# --- STAGE 2: Runtime ---
FROM alpine:latest
RUN apk add --no-cache ca-certificates openssl nginx bash gettext

WORKDIR /app
COPY --from=builder /go/bin/tesla-http-proxy /usr/local/bin/

# 1. CONFIGURAZIONE NGINX CON CONTROLLO CHIAVE
RUN echo 'server { \
    listen ${PORT}; \
    \
    access_log /dev/stdout; \
    error_log /dev/stderr; \
    \
    location = / { \
        return 200 "OK"; \
    } \
    \
    location /callback { \
        return 302 "greencharge://auth/callback?code=$arg_code&state=$arg_state"; \
    } \
    \
    location /.well-known/appspecific/ { \
        root /var/www/html; \
        location ~* \.json$ { add_header Content-Type application/json; } \
        location ~* \.pem$  { add_header Content-Type application/x-pem-file; } \
    } \
    \
    location / { \
        # --- LOGICA DI SICUREZZA --- \
        # Verifichiamo che l header X-Proxy-Secure-Key sia uguale alla variabile ENV \
        if ($http_x_proxy_secure_key != "${SECURE_KEY}") { \
            return 401 "Unauthorized: Invalid Security Key"; \
        } \
        \
        proxy_pass https://127.0.0.1:10001; \
        proxy_ssl_verify off; \
        proxy_http_version 1.1; \
        proxy_set_header Host $host; \
        proxy_set_header X-Real-IP $remote_addr; \
    } \
}' > /etc/nginx/http.d/default.conf.template

# 2. START SCRIPT
RUN cat <<-'EOF' > /app/start.sh
#!/bin/bash
# Generazione certificati per il server proxy
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout /app/proxy.key -out /app/proxy.crt \
    -days 365 -subj '/CN=localhost'

mkdir -p /var/www/html/.well-known/appspecific/

# Ora iniettiamo sia PORT che SECURE_KEY nella configurazione Nginx
envsubst '${PORT} ${SECURE_KEY}' < /etc/nginx/http.d/default.conf.template > /etc/nginx/http.d/default.conf

if [ -f /etc/secrets/public.pem ]; then
    PUB_KEY=$(grep -v '-' /etc/secrets/public.pem | tr -d '\n\r')
    echo "{\"domain\":\"gc-53r0.onrender.com\",\"public_key\":\"$PUB_KEY\"}" > /var/www/html/.well-known/appspecific/com.tesla.3p.json
    cp /etc/secrets/public.pem /var/www/html/.well-known/appspecific/com.tesla.3p.public-key.pem
fi

chmod -R 755 /var/www/html
nginx

echo "[LOG] Avvio tesla-http-proxy con i flag estratti dal log..."
exec tesla-http-proxy \
    -port 10001 \
    -host 127.0.0.1 \
    -key-file /etc/secrets/private.pem \
    -cert /app/proxy.crt \
    -tls-key /app/proxy.key \
    -verbose
EOF

RUN chmod +x /app/start.sh
ENTRYPOINT ["/bin/bash", "/app/start.sh"]
