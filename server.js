FROM golang:1.23-alpine AS builder
RUN apk add --no-cache git openssl
RUN git clone https://github.com/teslamotors/vehicle-command.git /app
WORKDIR /app
RUN go install ./cmd/tesla-http-proxy

FROM alpine:latest
RUN apk add --no-cache ca-certificates openssl
COPY --from=builder /go/bin/tesla-http-proxy /usr/local/bin/

EXPOSE 10000

# Genera i certificati TLS necessari e avvia il proxy sui parametri corretti
CMD ["sh", "-c", "openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout /tmp/tls.key -out /tmp/tls.crt -days 365 -subj '/CN=localhost' && \
    tesla-http-proxy \
    -port 10000 \
    -host 0.0.0.0 \
    -key-file /etc/secrets/private.pem \
    -tls-key /tmp/tls.key \
    -cert /tmp/tls.crt \
    -verbose"]
