FROM golang:1.23-alpine AS builder
RUN apk add --no-cache git
RUN git clone https://github.com/teslamotors/vehicle-command.git /app
WORKDIR /app
RUN go install ./cmd/tesla-http-proxy

FROM alpine:latest
RUN apk add --no-cache ca-certificates openssl nginx

COPY --from=builder /go/bin/tesla-http-proxy /usr/local/bin/

# Configurazione Nginx con backslash corretti per ogni riga
RUN echo 'server { \
    listen 10000; \
    location ^~ /.well-known/appspecific/com.tesla.3p.json { \
        alias /var/www/html/tesla.json; \
        add_header Content-Type application/json; \
        add_header Access-Control-Allow-Origin *; \
    } \
    location ^~ /.well-known/appspecific/com.tesla.3p.public-key.pem { \
        alias /var/www/html/com.tesla.3p.public-key.pem; \
        add_header Content-Type text/plain; \
    } \
    location /callback { \
        if ($arg_code) { \
            return 302 greencharge://auth?code=$arg_code; \
        } \
        return 200 "Codice non trovato"; \
    } \
    location / { \
        proxy_pass https://127.0.0.1:10001; \
        proxy_ssl_verify off; \
        proxy_set_header Host $host; \
        proxy_set_header X-Real-IP $remote_addr; \
    } \
}' > /etc/nginx/http.d/default.conf

EXPOSE 10000

CMD ["sh", "-c", "openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout /tmp/tls.key -out /tmp/tls.crt -days 365 -subj '/CN=localhost' && \
    mkdir -p /var/www/html && \
    if [ -f /etc/secrets/public.pem ]; then \
        PUB_KEY=$(grep -v '^-' /etc/secrets/public.pem | tr -d '\n\r'); \
        echo \"{\\\"domain\\\":\\\"gc-53r0.onrender.com\\\",\\\"public_key\\\":\\\"$PUB_KEY\\\"}\" > /var/www/html/tesla.json; \
        cp /etc/secrets/public.pem /var/www/html/com.tesla.3p.public-key.pem; \
        chmod 644 /var/www/html/tesla.json /var/www/html/com.tesla.3p.public-key.pem; \
    else \
        echo '{\"error\":\"file public.pem missing\"}' > /var/www/html/tesla.json; \
    fi && \
    nginx && \
    tesla-http-proxy -port 10001 -host 127.0.0.1 -key-file /etc/secrets/private.pem -tls-key /tmp/tls.key -cert /tmp/tls.crt -verbose"]
