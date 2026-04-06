# Sentinel

[![CI](https://github.com/jarlah/sentinel/actions/workflows/ci.yml/badge.svg)](https://github.com/jarlah/sentinel/actions/workflows/ci.yml)

Programmable infrastructure health monitoring as a single Haskell binary. Probes your services and databases on a schedule, tracks status, and exposes results as a JSON API.

Built on [http-tower-hs](https://github.com/jarlah/http-tower-hs) and [tower-hs](https://github.com/jarlah/tower-hs) — every probe (HTTP or database) flows through a composable middleware stack with circuit breakers, retries, and timeouts.

## Quick start

```yaml
# config.yaml
port: 8080

probes:
  - name: my-app
    url: "https://myapp.example.com/health"

  - name: main-db
    type: postgres
    connection_string: "host=localhost port=5432 dbname=mydb user=postgres password=secret"

  - name: cache
    type: redis
    connection_string: "redis://localhost:6379"
```

```
$ sentinel config.yaml
Sentinel starting on port 8080
Monitoring 3 probes
Tracing: disabled
[probe:my-app] "GET" "myapp.example.com" "/health" -> 200 (89ms)
```

```
$ curl localhost:8080/status
[
  {
    "name": "my-app",
    "status": "up",
    "latency_ms": 89.4,
    "error": null,
    "checked_at": "2026-04-04T14:58:07Z"
  },
  {
    "name": "main-db",
    "status": "up",
    "latency_ms": 3.2,
    "error": null,
    "checked_at": "2026-04-04T14:58:07Z"
  },
  {
    "name": "cache",
    "status": "up",
    "latency_ms": 1.1,
    "error": null,
    "checked_at": "2026-04-04T14:58:07Z"
  }
]
```

For HTTP probes, only `name` and `url` are required. For database probes, specify the `type` and connection details. Everything else is optional.

## Configuration

### Minimal

```yaml
probes:
  - name: my-app
    url: "https://myapp.example.com/health"
```

This gives each probe: User-Agent (`sentinel/0.1.0`), a unique request ID, and logging. No retry, no timeout, no validation — just a raw health check.

### Full

```yaml
port: 8080
tracing: true

alerting:
  slack:
    webhook_url: "https://hooks.slack.com/services/T.../B.../xxx"
  resend:
    api_key: "re_xxx"
    from: "sentinel@example.com"
    to: ["oncall@example.com"]
  prometheus:
    pushgateway_url: "http://localhost:9091"

probes:
  # HTTP probes (type defaults to "http")
  - name: my-app
    url: "https://myapp.example.com/health"
    interval_seconds: 15
    timeout_ms: 3000
    retries: 3
    follow_redirects: 5
    expected_status: [200, 299]
    alert_after: 3
    alert_reminder: 3600
    alerts: [slack, resend]
    circuit_breaker:
      failure_threshold: 5
      cooldown_seconds: 60
    headers:
      - ["Authorization", "Bearer my-secret-token"]
      - ["Accept", "application/json"]

  - name: external-api
    url: "https://api.partner.com/v1/status"
    interval_seconds: 60
    timeout_ms: 10000
    retries: 1
    expected_status: [200, 200]

  - name: redirect-check
    url: "https://old.example.com"
    follow_redirects: 3

  - name: internal-service
    url: "https://internal.example.com/health"
    tls_ca_path: "/etc/sentinel/ca.pem"
    tls_client_cert: "/etc/sentinel/client.pem"
    tls_client_key: "/etc/sentinel/client-key.pem"

  # Database probes
  - name: main-db
    type: postgres
    connection_string: "host=localhost port=5432 dbname=mydb user=postgres password=secret"
    interval_seconds: 30
    timeout_ms: 5000
    retries: 2
    circuit_breaker:
      failure_threshold: 5
      cooldown_seconds: 60

  - name: cache
    type: redis
    connection_string: "redis://localhost:6379"
    interval_seconds: 15
    timeout_ms: 3000

  - name: app-mysql
    type: mysql
    host: "localhost"
    port: 3306
    user: "monitor"
    password: "secret"
    database: "mydb"
    interval_seconds: 30
```

### Probe types

Sentinel supports HTTP and database probes. Set the `type` field to choose:

| Type | Description | Required fields |
|---|---|---|
| `http` (default) | HTTP GET health check | `url` |
| `postgres` | PostgreSQL connection ping (`SELECT 1`) | `connection_string` |
| `mysql` | MySQL/MariaDB connection ping (`COM_PING`) | `host`, `user`, `password` |
| `redis` | Redis connection ping (`PING`) | `connection_string` (default: `redis://localhost:6379`) |

Database probes create a fresh connection, execute the health check, and close. This tests that the database accepts new connections — not just that the port is open.

### Shared config reference

These fields apply to all probe types:

| Field | Type | Default | Description |
|---|---|---|---|
| `name` | string | **required** | Probe identifier (used in API responses and logs) |
| `type` | string | `http` | Probe type: `http`, `postgres`, `mysql`, `redis` |
| `interval_seconds` | int | 30 | Seconds between probes |
| `timeout_ms` | int | *none* | Request timeout in milliseconds |
| `retries` | int | *none* | Retry count with 1s constant backoff |
| `circuit_breaker.failure_threshold` | int | 5 | Consecutive failures before tripping |
| `circuit_breaker.cooldown_seconds` | int | 30 | Seconds before probing recovery |
| `alert_after` | int | 1 | Consecutive failures before alerting |
| `alert_reminder` | int | 0 | Seconds between reminder alerts while still down (0 = no reminders) |
| `alerts` | [string] | *all* | Which channels to use: `slack`, `resend`, `prometheus` |

### HTTP-specific config

| Field | Type | Default | Description |
|---|---|---|---|
| `url` | string | **required** | URL to probe |
| `follow_redirects` | int | *none* | Max redirect hops (301/302/303/307/308) |
| `expected_status` | [int, int] | *none* | Accepted status code range [min, max] inclusive |
| `headers` | [[name, value]] | *none* | Custom headers added to every request |
| `tls_ca_path` | string | *none* | Path to a custom CA certificate (PEM) for TLS verification |
| `tls_client_cert` | string | *none* | Path to client certificate (PEM) for mTLS |
| `tls_client_key` | string | *none* | Path to client private key (PEM) for mTLS |

### MySQL-specific config

| Field | Type | Default | Description |
|---|---|---|---|
| `host` | string | `localhost` | MySQL server hostname |
| `port` | int | 3306 | MySQL server port |
| `user` | string | `root` | MySQL username |
| `password` | string | `""` | MySQL password |
| `database` | string | `""` | MySQL database name |

### Global config

| Field | Type | Default | Description |
|---|---|---|---|
| `tracing` | bool | false | Enable OpenTelemetry tracing for HTTP probes |

### Alerting channels

```yaml
alerting:
  slack:
    webhook_url: "https://hooks.slack.com/services/T.../B.../xxx"
  resend:
    api_key: "re_xxx"                     # Resend API key
    from: "sentinel@example.com"
    to: ["oncall@example.com"]
  prometheus:
    pushgateway_url: "http://localhost:9091"
    job: "sentinel"
```

| Field | Description |
|---|---|
| `alerting.slack.webhook_url` | Slack incoming webhook URL |
| `alerting.resend.api_key` | Resend API key |
| `alerting.resend.from` | Sender email address |
| `alerting.resend.to` | List of recipient email addresses |
| `alerting.prometheus.pushgateway_url` | Prometheus Pushgateway URL |
| `alerting.prometheus.job` | Job label for pushed metrics (default: `sentinel`) |

All alerting config is optional. If `alerting` is absent, no alerts are sent.

## Alerting

Sentinel alerts on **state transitions** — not every probe result:

| Transition | Alert | Example |
|---|---|---|
| Up → Down | `:red_circle: **my-app** is DOWN — connection refused` | After `alert_after` consecutive failures |
| Down → Down | `:warning: **my-app** is still DOWN` | Every `alert_reminder` seconds |
| Down → Up | `:large_green_circle: **my-app** recovered (89ms)` | Immediately |
| Up → Up | *no alert* | |

Alerts fire asynchronously — a Slack outage won't block health monitoring. All alert HTTP calls go through http-tower-hs with retry and timeout.

### Prometheus metrics

When configured, Sentinel pushes gauges to a Pushgateway:

```
sentinel_probe_up{probe="my-app"} 1
sentinel_probe_latency_ms{probe="my-app"} 89.4
```

Use Alertmanager rules on these metrics for more advanced alerting workflows.

## Middleware stack

Sentinel uses composable middleware from [tower-hs](https://github.com/jarlah/tower-hs) for all probe types.

### HTTP probes

HTTP probes build an [http-tower-hs](https://github.com/jarlah/http-tower-hs) middleware stack. Only configured middleware is applied:

```
User-Agent ─> Request ID ─> Headers ─> Redirects ─> Retry ─> Timeout ─> Validate ─> Circuit Breaker ─> Tracing ─> Logging
  (always)     (always)    (optional)  (optional)  (optional) (optional) (optional)    (optional)      (optional)  (always)
```

```haskell
-- What sentinel builds under the hood for HTTP probes:
client <- newClientWithTLS maybeCaPath maybeClientCert
let configured = client
      |> withUserAgent "sentinel/0.1.0"
      |> withRequestId
      |> withHeader "Authorization" "Bearer my-token"
      |> withFollowRedirects 5
      |> withRetry (constantBackoff 3 1.0)
      |> withTimeout 3000
      |> withValidateStatus (\c -> c >= 200 && c < 300)
      |> withCircuitBreaker cbConfig breaker
      |> withTracing
      |> withLogging logger
```

### Database probes

Database probes use tower-hs's protocol-agnostic `Service` type directly. A `Service () ()` wrapping the database ping is composed with the same middleware primitives:

```
Retry ─> Timeout ─> Circuit Breaker ─> DB Ping
```

This means a downed database gets the same circuit breaker protection as HTTP services — after the failure threshold, sentinel stops attempting connections until the cooldown period elapses.

### Circuit breaker

When configured, each probe gets its own circuit breaker. After `failure_threshold` consecutive failures, the breaker trips open and immediately rejects probe requests (no wasted HTTP calls or database connections to a known-dead service). After `cooldown_seconds`, it allows one probe through to test recovery.

## API

| Endpoint | Method | Description |
|---|---|---|
| `/status` | GET | JSON array of all probe results |

### Response format

```json
[
  {
    "name": "my-app",
    "status": "up",
    "latency_ms": 89.4,
    "error": null,
    "checked_at": "2026-04-04T14:58:07Z"
  },
  {
    "name": "external-api",
    "status": "down",
    "latency_ms": 5012.3,
    "error": "Request timed out",
    "checked_at": "2026-04-04T14:58:12Z"
  }
]
```

## Building and running

```bash
stack build
stack run -- config.yaml

# Or directly:
stack exec sentinel -- config.yaml
```

## License

MIT
