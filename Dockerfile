FROM golang:1.23-alpine AS builder
RUN apk add --no-cache git
RUN git clone https://github.com/teslamotors/vehicle-command.git /app
WORKDIR /app
RUN go install ./cmd/tesla-http-proxy

FROM alpine:latest
RUN apk add --no-cache ca-certificates openssl nginx

# Copiamo il binario
COPY --from=builder /go/bin/tesla-http-proxy /usr/local/bin/

# Creiamo la configurazione Nginx (ascolta su 10000 e gira su 10001)
RUN echo 'server { \
    listen 10000; \
    location / { \
        proxy_pass https://127.0.0.1:10001; \
        proxy_ssl_verify off; \
        proxy_set_header Host $host; \
        proxy_set_header X-Real-IP $remote_addr; \
    } \
}' > /etc/nginx/http.d/default.conf

EXPOSE 10000

# Generiamo i certificati E avviamo tutto nello stesso comando
CMD ["sh", "-c", "openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout /etc/ssl/private/tls.key -out /etc/ssl/certs/tls.crt -days 365 -subj '/CN=localhost' && \
    nginx && \
    tesla-http-proxy \
    -port 10001 \
    -host 127.0.0.1 \
    -key-file /etc/secrets/private.pem \
    -tls-key /etc/ssl/private/tls.key \
    -cert /etc/ssl/certs/tls.crt \
    -verbose"]
