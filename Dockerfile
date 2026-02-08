FROM nimlang/nim:2.2.6-alpine-regular AS build

WORKDIR /app
COPY src/ src/
COPY tests/ tests/

# Run tests
RUN nim c -r tests/test_metrics.nim
RUN nim c -r tests/test_collector.nim

# Build release binary
RUN nim c \
    -d:release \
    -d:ssl \
    --opt:size \
    --threads:on \
    -o:/app/tado_exporter \
    src/tado_exporter.nim

FROM alpine:3.21

RUN apk add --no-cache libssl3 libcrypto3 ca-certificates
COPY --from=build /app/tado_exporter /usr/local/bin/tado_exporter

EXPOSE 9617

ENTRYPOINT ["/usr/local/bin/tado_exporter"]
