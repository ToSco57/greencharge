FROM golang:1.23-alpine AS builder
RUN apk add --no-cache git
RUN git clone https://github.com/teslamotors/vehicle-command.git /app
WORKDIR /app
RUN go install ./cmd/tesla-http-proxy

FROM alpine:latest
RUN apk add --no-cache ca-certificates
COPY --from=builder /go/bin/tesla-http-proxy /usr/local/bin/

EXPOSE 10000

# Rimuoviamo i flag -tls-key e -cert. 
# Il proxy ora accetterà HTTP internamente (quello che vuole Render)
# ma Render lo esporrà comunque in HTTPS all'esterno.
CMD ["sh", "-c", "echo '--- DEPLOY VERSION: HTTP-INTERNAL ---' && \
    tesla-http-proxy \
    -port 10000 \
    -host 0.0.0.0 \
    -key-file /etc/secrets/private.pem \
    -verbose"]
