# Usa Go per compilare il proxy ufficiale Tesla
FROM golang:1.21-alpine AS builder
RUN apk add --no-cache git
# Scarica il codice sorgente ufficiale di Tesla
RUN git clone https://github.com/teslamotors/vehicle-command.git /app
WORKDIR /app
# Compila il binario del proxy
RUN go install ./cmd/tesla-http-proxy

# Immagine finale pulita
FROM alpine:latest
RUN apk add --no-cache ca-certificates
COPY --from=builder /go/bin/tesla-http-proxy /usr/local/bin/

# Espone la porta HTTPS per Render
EXPOSE 10000

# Avvio del proxy: legge la chiave dai Secret Files di Render
CMD ["tesla-http-proxy", "-addr", ":10000", "-key-file", "/etc/secrets/private.pem"]
