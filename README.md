# Tado Exporter

A Prometheus exporter for **Tado** smart thermostats, written in Nim with zero external dependencies.

Queries 3 Tado API endpoints concurrently to expose per-zone heating metrics — temperature, humidity, heating power, window state, and presence detection. Uses OAuth2 device code flow for authentication and background polling to decouple scrape frequency from API rate limits.

## Architecture

On startup, the exporter authenticates via OAuth2 device code flow (you visit a URL and enter a code), discovers your home and zones, then polls the Tado API in the background at a configurable interval. The `/metrics` endpoint always returns instantly from cache — it never triggers an API call.

```
┌──────────────────────────────────────────────┐
│  Tado Exporter                               │
│                                              │
│  background poller ──► Tado API (3 requests) │
│       │                                      │
│       ▼                                      │
│  cached metrics ◄── /metrics (instant)       │
└──────────────────────┬───────────────────────┘
                       │
              ┌────────▼─────────┐
              │  vmagent /       │
              │  prometheus      │
              └──────────────────┘
```

## Metrics

| Category | Source Endpoint | Metrics |
|----------|----------------|---------|
| **Weather** | `/homes/{id}/weather` | `tado_temperature_outside_celsius`, `tado_solar_intensity_percentage` |
| **Presence** | `/homes/{id}/state` | `tado_is_resident_present` |
| **Zone state** | `/homes/{id}/zoneStates` | `tado_temperature_measured_celsius{zone_name,zone_id,home_id,zone_type}`, `tado_temperature_set_celsius{…}`, `tado_humidity_measured_percentage{…}`, `tado_heating_power_percentage{…}`, `tado_is_window_open{…}`, `tado_is_zone_powered{…}` |
| **Exporter** | — | `tado_exporter_scrape_duration_seconds`, `tado_exporter_scrape_success`, `tado_exporter_authentication_valid` |
| **Rate limit** | — | `tado_exporter_ratelimit_remaining`, `tado_exporter_ratelimit_exhausted` |

## Quick Start

### Docker

```yaml
services:
  tado-exporter:
    image: ghcr.io/nbx3/tado-exporter:latest
    volumes:
      - tado-data:/data
    ports:
      - "9618:9618"
```

On first run, check the logs for the authorization URL:

```
=== Tado Authorization Required ===
Visit: https://login.tado.com/...
Code:  ABCD-1234
Waiting for authorization...
```

Visit the URL, enter the code, and the exporter will start collecting metrics. The token is persisted to `/data/tado-token.json` so you only need to authorize once.

### Binary

```sh
TADO_TOKEN_PATH=./tado-token.json \
./tado_exporter
```

Then scrape `http://localhost:9618/metrics` with Prometheus.

## Configuration

All configuration is via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `TADO_PORT` | `9617` | Metrics server listen port |
| `TADO_TOKEN_PATH` | `/data/tado-token.json` | Path to persist OAuth2 token |
| `TADO_POLL_INTERVAL` | `2700` | Seconds between API polls (minimum 300) |
| `LOG_LEVEL` | `INFO` | Log verbosity: `DEBUG`, `INFO`, `WARN`, `ERROR`, `FATAL`, `NONE` |

### Rate Limiting

The Tado API enforces daily rate limits (100 requests/day for free users, 20,000 for premium). Each poll makes 3 API requests. The default 2700s (45 min) interval keeps free-tier usage under the limit (~96 requests/day). The exporter reads the `ratelimit` response header and will automatically pause polling when the quota is exhausted, resuming after the refill window. The minimum poll interval is 300s (5 min).

## Endpoints

| Path | Description |
|------|-------------|
| `/metrics` | Prometheus metrics |
| `/health` | Health check (`200 OK` or `503` if last poll failed) |
| `/` | Landing page with link to metrics |

## Building

Requires [Nim](https://nim-lang.org/) >= 2.0.

```sh
nim c -d:release -d:ssl --opt:size -o:tado_exporter src/tado_exporter.nim
```

### Docker

```sh
docker build -t tado-exporter .
```

The Dockerfile runs all unit tests first, then produces a minimal Alpine image with SSL support. If any test fails, the build is aborted.

### Testing

Tests are in `tests/` and run automatically during `docker build`. They can also be run directly with Nim:

```sh
nim c -r tests/test_metrics.nim
nim c -r tests/test_collector.nim
```

- **test_metrics** — Prometheus text format rendering: label escaping, value formatting, metric declaration
- **test_collector** — All collector procs against JSON fixtures, including JNull safety

## Prometheus Config

```yaml
scrape_configs:
  - job_name: tado
    static_configs:
      - targets: ["tado-exporter:9617"]
```

## License

MIT
