FROM golang:1.23-alpine AS builder
RUN apk add --no-cache git
RUN git clone https://github.com/teslamotors/vehicle-command.git /app
WORKDIR /app
RUN go install ./cmd/tesla-http-proxy

FROM alpine:latest
RUN apk add --no-cache ca-certificates openssl nginx

# 1. Copiamo il binario
COPY --from=builder /go/bin/tesla-http-proxy /usr/local/bin/

# 2. Generiamo i certificati interni (per far stare zitto il proxy Tesla)
RUN openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout /tmp/tls.key -out /tmp/tls.crt -days 365 -subj '/CN=localhost'

# 3. Creiamo una configurazione Nginx che faccia da ponte
RUN echo 'server { \
    listen 10000; \
    location / { \
        proxy_pass https://127.0.0.1:10001; \
        proxy_ssl_verify off; \
        proxy_set_header Host $host; \
    } \
}' > /etc/nginx/http.d/default.conf

EXPOSE 10000

# 4. Avviamo Nginx e il Proxy Tesla insieme
# Nginx ascolta sulla 10000 (quella di Render)
# Tesla ascolta sulla 10001 (interna)
CMD ["sh", "-c", "nginx && tesla-http-proxy \
    -port 10001 \
    -host 127.0.0.1 \
    -key-file /etc/secrets/private.pem \
    -tls-key /tmp/tls.key \
    -cert /tmp/tls.crt \
    -verbose"]
