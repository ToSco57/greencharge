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

# 1. CONFIGURAZIONE NGINX
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
        proxy_pass https://127.0.0.1:10001; \
        proxy_ssl_verify off; \
        proxy_http_version 1.1; \
        proxy_set_header Host $host; \
        proxy_set_header X-Real-IP $remote_addr; \
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; \
    } \
}' > /etc/nginx/http.d/default.conf.template

# 2. START SCRIPT
RUN cat <<-'EOF' > /app/start.sh
#!/bin/bash
# Creiamo i file TLS espliciti per evitare l'errore "no such file or directory"
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout /app/proxy-tls.key -out /app/proxy-tls.crt \
    -days 365 -subj '/CN=localhost'

mkdir -p /var/www/html/.well-known/appspecific/
envsubst '${PORT}' < /etc/nginx/http.d/default.conf.template > /etc/nginx/http.d/default.conf

if [ -f /etc/secrets/public.pem ]; then
    PUB_KEY=$(grep -v '-' /etc/secrets/public.pem | tr -d '\n\r')
    echo "{\"domain\":\"gc-53r0.onrender.com\",\"public_key\":\"$PUB_KEY\"}" > /var/www/html/.well-known/appspecific/com.tesla.3p.json
    cp /etc/secrets/public.pem /var/www/html/.well-known/appspecific/com.tesla.3p.public-key.pem
fi

chmod -R 755 /var/www/html
nginx

echo "[LOG] Avvio tesla-http-proxy con certificati locali..."
# Usiamo i file appena creati. Assicurati che /etc/secrets/private.pem esista su Render!
exec tesla-http-proxy -port 10001 -host 127.0.0.1 \
    -key-file /etc/secrets/private.pem \
    -tls-key /app/proxy-tls.key \
    -tls-cert /app/proxy-tls.crt \
    -verbose
EOF

RUN chmod +x /app/start.sh
ENTRYPOINT ["/bin/bash", "/app/start.sh"]    location / { \
        # Passiamo in HTTP al proxy per evitare errori di handshake interni \
        proxy_pass http://127.0.0.1:10001; \
        proxy_http_version 1.1; \
        proxy_set_header Host $host; \
        proxy_set_header X-Real-IP $remote_addr; \
    } \
}' > /etc/nginx/http.d/default.conf.template

# 2. START SCRIPT
RUN cat <<-'EOF' > /app/start.sh
#!/bin/bash
mkdir -p /var/www/html/.well-known/appspecific/
envsubst '${PORT}' < /etc/nginx/http.d/default.conf.template > /etc/nginx/http.d/default.conf

if [ -f /etc/secrets/public.pem ]; then
    PUB_KEY=$(grep -v '-' /etc/secrets/public.pem | tr -d '\n\r')
    echo "{\"domain\":\"gc-53r0.onrender.com\",\"public_key\":\"$PUB_KEY\"}" > /var/www/html/.well-known/appspecific/com.tesla.3p.json
    cp /etc/secrets/public.pem /var/www/html/.well-known/appspecific/com.tesla.3p.public-key.pem
fi

chmod -R 755 /var/www/html
nginx

echo "[LOG] Sistema pronto. Proxy in ascolto su HTTP 10001 (Internal)"
# Rimosso -tls-key e -cert per parlare in HTTP con Nginx localmente
exec tesla-http-proxy -port 10001 -host 127.0.0.1 -key-file /etc/secrets/private.pem -verbose
EOF

RUN chmod +x /app/start.sh
ENTRYPOINT ["/bin/bash", "/app/start.sh"]
