# ... (tutto il resto uguale fino al CMD)

# Lanciamo il proxy con i nomi dei flag corretti visti nel tuo log
CMD ["sh", "-c", "tesla-http-proxy \
    -port ${PORT:-10000} \
    -host 0.0.0.0 \
    -key-file /etc/secrets/private.pem \
    -tls-key /tmp/tls.key \
    -cert /tmp/tls.crt \
    -verbose"]
