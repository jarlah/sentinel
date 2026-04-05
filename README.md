# Sentinel

Programmable infrastructure health monitoring as a single Haskell binary. Probes your services on a schedule, tracks status, and exposes results as a JSON API.

Built on [http-tower-hs](https://github.com/jarls-side-projects/http-tower-hs) — every outbound HTTP request flows through a composable middleware stack.

## Quick start

```yaml
# config.yaml
port: 8080

probes:
  - name: my-app
    url: "https://myapp.example.com/health"
```

```
$ sentinel config.yaml
Sentinel starting on port 8080
Monitoring 1 probes
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
  }
]
```

Only `name` and `url` are required. Everything else is optional.

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
  email:
    api_key: "re_xxx"
    from: "sentinel@example.com"
    to: ["oncall@example.com"]
  prometheus:
    pushgateway_url: "http://localhost:9091"

probes:
  - name: my-app
    url: "https://myapp.example.com/health"
    interval_seconds: 15
    timeout_ms: 3000
    retries: 3
    follow_redirects: 5
    expected_status: [200, 299]
    alert_after: 3
    alert_reminder: 3600
    alerts: [slack, email]
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
```

### Config reference

| Field | Type | Default | Description |
|---|---|---|---|
| `name` | string | **required** | Probe identifier (used in API responses and logs) |
| `url` | string | **required** | URL to probe |
| `interval_seconds` | int | 30 | Seconds between probes |
| `timeout_ms` | int | *none* | Request timeout in milliseconds |
| `retries` | int | *none* | Retry count with 1s constant backoff |
| `follow_redirects` | int | *none* | Max redirect hops (301/302/303/307/308) |
| `expected_status` | [int, int] | *none* | Accepted status code range [min, max] inclusive |
| `circuit_breaker.failure_threshold` | int | 5 | Consecutive failures before tripping |
| `circuit_breaker.cooldown_seconds` | int | 30 | Seconds before probing recovery |
| `headers` | [[name, value]] | *none* | Custom headers added to every request |
| `alert_after` | int | 1 | Consecutive failures before alerting |
| `alert_reminder` | int | 0 | Seconds between reminder alerts while still down (0 = no reminders) |
| `alerts` | [string] | *all* | Which channels to use: `slack`, `email`, `prometheus` |
| `tracing` | bool | false | Global: enable OpenTelemetry tracing |

### Alerting channels

```yaml
alerting:
  slack:
    webhook_url: "https://hooks.slack.com/services/T.../B.../xxx"
  email:
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
| `alerting.email.api_key` | Resend API key |
| `alerting.email.from` | Sender email address |
| `alerting.email.to` | List of recipient email addresses |
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

Each probe builds its own [http-tower-hs](https://github.com/jarls-side-projects/http-tower-hs) middleware stack from config. Only configured middleware is applied:

```
User-Agent ─> Request ID ─> Headers ─> Redirects ─> Retry ─> Timeout ─> Validate ─> Circuit Breaker ─> Tracing ─> Logging
  (always)     (always)    (optional)  (optional)  (optional) (optional) (optional)    (optional)      (optional)  (always)
```

```haskell
-- What sentinel builds under the hood:
client <- newClient
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

### Circuit breaker

When configured, each probe gets its own circuit breaker. After `failure_threshold` consecutive failures, the breaker trips open and immediately rejects probe requests (no wasted HTTP calls to a known-dead service). After `cooldown_seconds`, it allows one probe through to test recovery.

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
