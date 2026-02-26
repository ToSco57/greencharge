# --- STAGE 1: Builder ---
FROM golang:1.23-alpine AS builder
RUN apk add --no-cache git
RUN git clone https://github.com/teslamotors/vehicle-command.git /app
WORKDIR /app
# Compiliamo solo il proxy, tesla-control non serve
RUN go install ./cmd/tesla-http-proxy

# --- STAGE 2: Runtime ---
FROM alpine:latest
# Rimosso Python e Flask: meno overhead, più stabilità
RUN apk add --no-cache ca-certificates openssl nginx bash gettext

WORKDIR /app
COPY --from=builder /go/bin/tesla-http-proxy /usr/local/bin/

# 1. CONFIGURAZIONE NGINX (Puro Bridge)
# Usiamo root e non alias per evitare errori di concatenazione dei path
RUN echo 'server { \
    listen ${PORT}; \
    \
    # Gestione Pairing Chiavi (Asset statici) \
    location /.well-known/appspecific/ { \
        root /var/www/html; \
        index index.json; \
        add_header Access-Control-Allow-Origin "*"; \
        \
        # Forza i MIME types corretti per Tesla \
        location ~* \.json$ { add_header Content-Type application/json; } \
        location ~* \.pem$  { add_header Content-Type application/x-pem-file; } \
    } \
    \
    # Proxy per tutti i comandi Tesla \
    location / { \
        proxy_pass https://127.0.0.1:10001; \
        proxy_ssl_verify off; \
        proxy_http_version 1.1; \
        proxy_set_header Host $host; \
        proxy_set_header Authorization $http_authorization; \
        proxy_pass_header Authorization; \
        proxy_buffering off; \
    } \
}' > /etc/nginx/http.d/default.conf.template

# 2. START SCRIPT
RUN cat <<-'EOF' > /app/start.sh
#!/bin/bash
# Certificati per TLS interno
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout /app/tls.key -out /app/tls.crt -days 365 -subj '/CN=localhost'

# CREAZIONE FISICA DEL PATH (Risolve il path errato nei log)
mkdir -p /var/www/html/.well-known/appspecific/

envsubst '${PORT}' < /etc/nginx/http.d/default.conf.template > /etc/nginx/http.d/default.conf

# Preparazione file per il pairing
if [ -f /etc/secrets/public.pem ]; then
    PUB_KEY=$(grep -v '-' /etc/secrets/public.pem | tr -d '\n\r')
    # Scriviamo i file con i nomi esatti cercati dall'URL
    echo "{\"domain\":\"gc-53r0.onrender.com\",\"public_key\":\"$PUB_KEY\"}" > /var/www/html/.well-known/appspecific/com.tesla.3p.json
    cp /etc/secrets/public.pem /var/www/html/.well-known/appspecific/com.tesla.3p.public-key.pem
fi

# Permessi ricorsivi (Risolve il 403 Forbidden)
chmod -R 755 /var/www/html

nginx
exec /usr/local/bin/tesla-http-proxy -port 10001 -host 127.0.0.1 -key-file /etc/secrets/private.pem -tls-key /app/tls.key -cert /app/tls.crt -verbose
EOF

RUN chmod +x /app/start.sh
ENTRYPOINT ["/bin/bash", "/app/start.sh"]
