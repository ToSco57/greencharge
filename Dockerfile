FROM golang:1.23-alpine AS builder
RUN apk add --no-cache git openssl
RUN git clone https://github.com/teslamotors/vehicle-command.git /app
WORKDIR /app
RUN go install ./cmd/tesla-http-proxy

FROM alpine:latest
RUN apk add --no-cache ca-certificates openssl
COPY --from=builder /go/bin/tesla-http-proxy /usr/local/bin/

# Generiamo un certificato TLS auto-firmato temporaneo (richiesto dal proxy per avviarsi)
RUN openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout /tmp/tls.key -out /tmp/tls.crt -days 365 \
    -subj "/CN=localhost"

EXPOSE 10000

# Lanciamo il proxy passando TUTTI i file richiesti:
# 1. -key-file: la tua chiave privata per la macchina
# 2. -tls-key e -cert: i certificati per il server web del proxy
CMD ["sh", "-c", "tesla-http-proxy \
    -port ${PORT:-10000} \
    -key-file /etc/secrets/private.pem \
    -tls-key /tmp/tls.key \
    -cert /tmp/tls.crt \
    -v"]
