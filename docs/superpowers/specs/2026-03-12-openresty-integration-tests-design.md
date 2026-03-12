# OpenResty Integration Tests Design

**Goal:** Add integration tests for the OpenResty adapter (`tls-clienthello-limiter.adapters.openresty`), validating all TLS rate limiting decision paths through vanilla OpenResty (no APISIX).

**Motivation:** The APISIX integration tests validate the monkey-patch adapter path. The OpenResty adapter uses a different code path (`ssl_client_hello_by_lua_block` directly), so all decision paths must be independently validated.

---

## Architecture

Two-service Docker Compose stack, fully isolated from the APISIX integration tests:

1. **openresty** — vanilla OpenResty with custom `nginx.conf` wiring the OpenResty adapter
2. **test-runner** — pytest container hitting the OpenResty TLS endpoint

No external dependencies. The OpenResty server returns static responses — no upstream backend needed.

## OpenResty Container

**Base image:** `openresty/openresty:jammy`

**Additional dependencies:** `nginx-lua-prometheus` (api7 fork) installed via luarocks.

**nginx.conf** wires the adapter through standard OpenResty directives:

- `lua_shared_dict` for `tls-hello-per-ip`, `tls-hello-per-domain`, `tls-ip-blocklist`, `prometheus-metrics`
- `lua_package_path` pointing to the mounted custom-plugins directory
- `init_worker_by_lua_block` calls `require("tls-clienthello-limiter.adapters.openresty").init(opts)` with the same rate/burst/ttl config as APISIX tests
- HTTPS server (port 443) with `ssl_client_hello_by_lua_block` calling `adapter.check()`
- Metrics server (port 9092) with `/metrics` endpoint using `prometheus:collect()` directly (no caching — always fresh)
- Healthz endpoint at `/healthz` on the metrics server

**Rate limiting config** (matches APISIX tests for apples-to-apples comparison):
- `per_ip_rate = 2`, `per_ip_burst = 4`
- `per_domain_rate = 5`, `per_domain_burst = 10`
- `block_ttl = 10`

## Metrics Endpoint

The `/metrics` endpoint calls `prometheus:collect()` synchronously in `content_by_lua_block`. Unlike APISIX's cached exporter, this returns live data with no refresh delay. The prometheus instance is created in `init_worker_by_lua_block` and stored in a shared Lua module table for access from the metrics handler.

Approach: the OpenResty adapter's `init()` auto-discovers the `prometheus` library and creates an instance from the `prometheus-metrics` shared dict. The metrics endpoint creates a second prometheus instance from the same shared dict to call `collect()`. Since nginx-lua-prometheus stores counter data in the shared dict, both instances see the same data.

## Test Coverage

Full mirror of APISIX integration tests:

### test_openresty_tls_rate_limit.py

| Test | Validates |
|---|---|
| `test_normal_handshake_succeeds` | Single TLS handshake passes |
| `test_rapid_handshakes_get_rejected` | Per-IP rate+burst exceeded → rejection |
| `test_rejected_ip_gets_auto_blocked` | Auto-block fires, metrics emitted |
| `test_blocked_handshakes_fail_immediately` | Blocked IP rejected on blocklist fast path |
| `test_block_expires_after_ttl` | Block TTL expires, handshake succeeds again |
| `test_per_domain_limit_triggers` | Per-SNI-domain rate exceeded → rejection |

### test_openresty_metrics.py

| Test | Validates |
|---|---|
| `test_passed_counter_increments` | `tls_clienthello_passed_total` appears |
| `test_blocked_counter_increments` | `tls_clienthello_blocked_total` or `tls_clienthello_rejected_total` appears |

### test_openresty_healthz.py

| Test | Validates |
|---|---|
| `test_healthz_endpoint_works` | `/healthz` returns 200 "ok" |

## File Structure

### New Files

| File | Responsibility |
|---|---|
| `integration/openresty-conf/nginx.conf` | OpenResty nginx configuration |
| `integration/openresty-conf/Dockerfile` | OpenResty image with luarocks deps + cert/config copy |
| `integration/openresty-tests/conftest.py` | pytest fixtures (TLS handshake helper, metrics fetcher) |
| `integration/openresty-tests/test_openresty_tls_rate_limit.py` | TLS rate limiting tests |
| `integration/openresty-tests/test_openresty_metrics.py` | Metrics counter tests |
| `integration/openresty-tests/test_openresty_healthz.py` | Healthz endpoint test |
| `integration/openresty-tests/requirements.txt` | pytest dependencies |
| `integration/openresty-tests/Dockerfile.test-runner` | Test runner image |
| `docker-compose.openresty-integration.yml` | Compose file for OpenResty integration stack |

### Modified Files

| File | Changes |
|---|---|
| `Makefile` | Add `openresty-integration` target, include in `all` |
| `integration/generate-conf.sh` | No change needed — certs are reused from existing generation |

## Docker Compose

```yaml
services:
  openresty:
    build:
      context: integration
      dockerfile: openresty-conf/Dockerfile
    volumes:
      - ./integration/custom-plugins:/usr/local/openresty/custom-plugins:ro
    ports:
      - "19443:443"
      - "19092:9092"
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://127.0.0.1:9092/healthz || exit 1"]
      interval: 2s
      timeout: 2s
      retries: 15

  test-runner:
    build:
      context: integration
      dockerfile: openresty-tests/Dockerfile.test-runner
    depends_on:
      openresty:
        condition: service_healthy
    environment:
      OPENRESTY_HTTPS_HOST: "openresty"
      OPENRESTY_HTTPS_PORT: "443"
      OPENRESTY_METRICS_URL: "http://openresty:9092/metrics"
      TEST_DOMAIN: "test.example.com"
```

## Key Differences from APISIX Tests

1. **No caching** — metrics endpoint returns live data, no sleep needed before assertions
2. **No APISIX prefix** — metric names are bare (e.g., `tls_clienthello_passed_total` not `apisix_tls_clienthello_passed_total`)
3. **Direct wiring** — `ssl_client_hello_by_lua_block` instead of monkey-patch
4. **Static backend** — `return 200 'ok'` instead of proxying to httpbin
