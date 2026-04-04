# Sentinel

Programmable infrastructure health monitoring as a single Haskell binary. Uses [http-tower-hs](https://github.com/jarls-side-projects/http-tower-hs) for composable HTTP client middleware.

## What it does

Sentinel reads a YAML config file defining HTTP endpoints to monitor, probes them on a schedule with retry/timeout/logging middleware, and exposes the results as a JSON API.

```
$ sentinel config.yaml
Sentinel starting on port 8080
Monitoring 2 probes
[probe:httpbin] "GET" "httpbin.org" "/get" -> 200 (156ms)
[probe:example] "GET" "example.com" "/" -> 200 (89ms)
```

```
$ curl localhost:8080/status
[
  {"name":"httpbin","status":"up","latency_ms":156.2,"error":null,"checked_at":"2026-04-04T14:58:08Z"},
  {"name":"example","status":"up","latency_ms":89.4,"error":null,"checked_at":"2026-04-04T14:58:07Z"}
]
```

## Configuration

```yaml
port: 8080

probes:
  - name: my-app
    url: "https://myapp.example.com/health"
    interval_seconds: 30
    timeout_ms: 5000
    retries: 2

  - name: external-api
    url: "https://api.example.com/status"
    interval_seconds: 60
    timeout_ms: 3000
    retries: 1
```

| Field              | Default | Description                          |
|--------------------|---------|--------------------------------------|
| `name`             | —       | Identifier for the probe             |
| `url`              | —       | URL to probe                         |
| `interval_seconds` | 30      | Seconds between probes               |
| `timeout_ms`       | 5000    | Request timeout in milliseconds      |
| `retries`          | 2       | Number of retries on failure         |

## How it uses http-tower-hs

Each probe gets its own middleware stack built from the config:

```haskell
client <- newClient
let configured = client
      |> withRetry (constantBackoff (probeRetries config) 1.0)
      |> withTimeout (probeTimeout config)
      |> withLogging logger
```

Retries, timeouts, and logging are handled by the middleware — the probe logic just calls `runRequest` and checks the `Either`.

## API

| Endpoint      | Method | Description                      |
|---------------|--------|----------------------------------|
| `/status`     | GET    | JSON array of all probe results  |

## Building and running

```bash
stack build
stack run -- config.yaml
```

Requires `http-tower-hs` as a sibling directory (referenced in `stack.yaml`). To use a git dependency instead, update `stack.yaml`:

```yaml
packages:
  - .
extra-deps:
  - git: https://github.com/jarls-side-projects/http-tower-hs.git
    commit: <commit-sha>
```

## License

MIT
