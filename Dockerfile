FROM nimlang/nim:2.2.2-alpine AS builder

RUN apk add --no-cache musl-dev openssl-dev openssl-libs-static

WORKDIR /src
COPY src/ src/

RUN nim c -d:release -d:ssl --opt:size --passL:"-static" \
    -o:/src/tado_exporter src/tado_exporter.nim && \
    strip tado_exporter

FROM alpine:3.21

RUN apk add --no-cache ca-certificates
COPY --from=builder /src/tado_exporter /usr/local/bin/tado_exporter

EXPOSE 9617

ENTRYPOINT ["/usr/local/bin/tado_exporter"]
