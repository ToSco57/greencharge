FROM golang:1.23-alpine AS builder
RUN apk add --no-cache git
RUN git clone https://github.com/teslamotors/vehicle-command.git /app
WORKDIR /app
RUN go install ./cmd/tesla-http-proxy

FROM alpine:latest
RUN apk add --no-cache ca-certificates
COPY --from=builder /go/bin/tesla-http-proxy /usr/local/bin/

# Espone la porta standard di Render
EXPOSE 10000

# Usiamo un comando che "pulisce" l'avvio:
# 1. Entriamo nella cartella delle chiavi (opzionale ma aiuta)
# 2. Lanciamo il proxy usando esplicitamente la porta di Render
CMD ["sh", "-c", "tesla-http-proxy -port ${PORT} -key-file /etc/secrets/private.pem"]
