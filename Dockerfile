FROM golang:1.23-alpine AS builder
RUN apk add --no-cache git
RUN git clone https://github.com/teslamotors/vehicle-command.git /app
WORKDIR /app
RUN go install ./cmd/tesla-http-proxy

FROM alpine:latest
RUN apk add --no-cache ca-certificates openssl nginx

COPY --from=builder /go/bin/tesla-http-proxy /usr/local/bin/

# Configurazione Nginx con priorità assoluta (^~)
RUN echo 'server { \
    listen 10000; \
    location ^~ /.well-known/appspecific/com.tesla.3p.json { \
        alias /var/www/html/tesla.json; \
        default_type application/json; \
        add_header Access-Control-Allow-Origin *; \
    } \
    location / { \
        proxy_pass https://127.0.0.1:10001; \
        proxy_ssl_verify off; \
        proxy_set_header Host $host; \
    } \
}' > /etc/nginx/http.d/default.conf

EXPOSE 10000

CMD ["sh", "-c", "openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout /tmp/tls.key -out /tmp/tls.crt -days 365 -subj '/CN=localhost' && \
    mkdir -p /var/www/html && \
    echo \"{\\\"public_key\\\":\\\"$(cat /etc/secrets/public.pub)\\\"}\" > /var/www/html/tesla.json && \
    nginx -g 'daemon on;' && \
    tesla-http-proxy -port 10001 -host 127.0.0.1 -key-file /etc/secrets/private.pem -tls-key /tmp/tls.key -cert /tmp/tls.crt -verbose"]
