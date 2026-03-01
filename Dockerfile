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
# Abbiamo aggiunto $upstream_status per vedere la risposta reale di Tesla
RUN echo 'log_format tesla_log "[$time_local] $request $status Upstream_Res: $upstream_status Time: $upstream_response_time"; \
server { \
    listen ${PORT}; \
    access_log /dev/stdout tesla_log; \
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
        proxy_pass http://127.0.0.1:10001; \
        proxy_http_version 1.1; \
        proxy_set_header Host $host; \
        proxy_set_header X-Real-IP $remote_addr; \
        proxy_set_header X-Forwarded-Proto $scheme; \
    } \
}' > /etc/nginx/http.d/default.conf.template

# 2. START SCRIPT
RUN cat <<-'EOF' > /app/start.sh
#!/bin/bash
# Certificati per Nginx (se servissero)
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout /app/tls.key -out /app/tls.crt -days 365 -subj '/CN=localhost'
mkdir -p /var/www/html/.well-known/appspecific/
envsubst '${PORT}' < /etc/nginx/http.d/default.conf.template > /etc/nginx/http.d/default.conf

if [ -f /etc/secrets/public.pem ]; then
    PUB_KEY=$(grep -v '-' /etc/secrets/public.pem | tr -d '\n\r')
    echo "{\"domain\":\"gc-53r0.onrender.com\",\"public_key\":\"$PUB_KEY\"}" > /var/www/html/.well-known/appspecific/com.tesla.3p.json
    cp /etc/secrets/public.pem /var/www/html/.well-known/appspecific/com.tesla.3p.public-key.pem
fi
chmod -R 755 /var/www/html

nginx
# RIMOSSI -tls-key e -cert: ora Go ascolta in HTTP sulla porta 10001
exec tesla-http-proxy -port 10001 -host 127.0.0.1 -key-file /etc/secrets/private.pem -verbose
EOF

RUN chmod +x /app/start.sh
ENTRYPOINT ["/bin/bash", "/app/start.sh"]        # Mostra gli header di risposta nei log per il debug \
        proxy_pass_header Server; \
    } \
}' > /etc/nginx/http.d/default.conf.template

# 2. START SCRIPT
RUN cat <<-'EOF' > /app/start.sh
#!/bin/bash
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout /app/tls.key -out /app/tls.crt -days 365 -subj '/CN=localhost'
mkdir -p /var/www/html/.well-known/appspecific/
envsubst '${PORT}' < /etc/nginx/http.d/default.conf.template > /etc/nginx/http.d/default.conf

if [ -f /etc/secrets/public.pem ]; then
    PUB_KEY=$(grep -v '-' /etc/secrets/public.pem | tr -d '\n\r')
    echo "{\"domain\":\"gc-53r0.onrender.com\",\"public_key\":\"$PUB_KEY\"}" > /var/www/html/.well-known/appspecific/com.tesla.3p.json
    cp /etc/secrets/public.pem /var/www/html/.well-known/appspecific/com.tesla.3p.public-key.pem
fi
chmod -R 755 /var/www/html

# Avviamo nginx in background e tesla-http-proxy in foreground
nginx
# Il flag -verbose stamperà i dettagli della richiesta inviata
exec tesla-http-proxy -port 10001 -host 127.0.0.1 -key-file /etc/secrets/private.pem -tls-key /app/tls.key -cert /app/tls.crt -verbose
EOF

RUN chmod +x /app/start.sh
ENTRYPOINT ["/bin/bash", "/app/start.sh"]
