# FASE 1: Compilazione (Builder)
FROM golang:1.23-alpine AS builder

# Installiamo git e openssl per la build e la gestione certificati
RUN apk add --no-cache git openssl

# Scarichiamo il codice sorgente ufficiale di Tesla
RUN git clone https://github.com/teslamotors/vehicle-command.git /app
WORKDIR /app

# Compiliamo il binario del proxy
RUN go install ./cmd/tesla-http-proxy

# FASE 2: Immagine Finale
FROM alpine:latest

# Installiamo le dipendenze necessarie per l'esecuzione
RUN apk add --no-cache ca-certificates openssl

# Copiamo il binario compilato dalla fase builder
COPY --from=builder /go/bin/tesla-http-proxy /usr/local/bin/

# Generiamo i certificati TLS auto-firmati temporanei. 
# Senza questi, il proxy Tesla non si avvia (causando l'errore 'open : no such file')
RUN openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout /tmp/tls.key -out /tmp/tls.crt -days 365 \
    -subj "/CN=localhost"

# Render usa solitamente la porta 10000
EXPOSE 10000

# COMANDO DI AVVIO
# -port: usa la variabile dinamica di Render
# -host 0.0.0.0: permette connessioni esterne
# -key-file: punta al file segreto caricato su Render
# -tls-key / -cert: puntano ai certificati generati sopra
# -verbose: abilita i log dettagliati (flag lungo, non -v)
CMD ["sh", "-c", "tesla-http-proxy \
    -port ${PORT:-10000} \
    -host 0.0.0.0 \
    -key-file /etc/secrets/private.pem \
    -tls-key /tmp/tls.key \
    -cert /tmp/tls.crt \
    -verbose"]
