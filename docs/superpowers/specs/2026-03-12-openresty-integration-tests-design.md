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

**Dockerfile** copies certs from `certs/` and the nginx.conf from `openresty-conf/` into the image. The custom-plugins directory is mounted as a volume at runtime.

**nginx.conf** wires the adapter through standard OpenResty directives:

- `lua_shared_dict` for `tls-hello-per-ip`, `tls-hello-per-domain`, `tls-ip-blocklist`, `prometheus-metrics`
- `lua_package_path` pointing to the mounted custom-plugins directory
- `init_worker_by_lua_block` calls `require("tls-clienthello-limiter.adapters.openresty").init(opts)` with the same rate/burst/ttl config as APISIX tests
- HTTPS server (port 443) with `ssl_client_hello_by_lua_block` calling `adapter.check()`
- Metrics server (port 9092) with `/metrics` endpoint calling `adapter.prometheus:collect()` (see Metrics section)
- Healthz endpoint at `/healthz` on the metrics server

**Rate limiting config** (matches APISIX tests for apples-to-apples comparison):
- `per_ip_rate = 2`, `per_ip_burst = 4`
- `per_domain_rate = 5`, `per_domain_burst = 10`
- `block_ttl = 10`

## Metrics Endpoint

The `/metrics` endpoint calls `prometheus:collect()` synchronously in `content_by_lua_block`. Unlike APISIX's cached exporter, this returns live data with no refresh delay.

**Single prometheus instance:** The OpenResty adapter's `init()` creates a prometheus instance internally and registers counters on it. This instance must be the same one used by the `/metrics` endpoint to call `collect()`, because `nginx-lua-prometheus` stores counter metadata in an in-memory registry per instance — a second instance from the same shared dict would have an empty registry and emit nothing.

**Solution:** Modify the OpenResty adapter to expose the prometheus instance as `_M.prometheus`. The metrics endpoint then accesses it via `require("tls-clienthello-limiter.adapters.openresty").prometheus:collect()`. This is a small change to `openresty.lua`: store the prometheus instance on `_M` after creation.

## Adapter Change

Add one line to `openresty.lua` in the `init()` function to expose the prometheus instance:

```lua
function _M.init(opts)
    -- ... existing code ...
    opts.metrics = metrics_adapter
    _M.prometheus = opts.prometheus or p  -- expose for metrics endpoint
    lim = core_mod.new(opts)
end
```

The variable `p` is the prometheus instance created during `init()`. If the caller passed `opts.prometheus`, use that; otherwise use the auto-discovered one. This is the only production code change.

## Test Coverage

Full mirror of APISIX integration tests, plus no-SNI path:

### test_openresty_tls_rate_limit.py

| Test | Validates |
|---|---|
| `test_normal_handshake_succeeds` | Single TLS handshake passes |
| `test_rapid_handshakes_get_rejected` | Per-IP rate+burst exceeded → rejection |
| `test_rejected_ip_gets_auto_blocked` | Auto-block fires, metrics emitted |
| `test_blocked_handshakes_fail_immediately` | Blocked IP rejected on blocklist fast path |
| `test_block_expires_after_ttl` | Block TTL expires, handshake succeeds again |
| `test_per_domain_limit_triggers` | Per-SNI-domain rate exceeded → rejection |
| `test_no_sni_handshake_passes` | TLS handshake without SNI extension succeeds, `tls_clienthello_no_sni_total` emitted |

### test_openresty_metrics.py

| Test | Validates |
|---|---|
| `test_passed_counter_increments` | `tls_clienthello_passed_total` appears |
| `test_blocked_counter_increments` | `tls_clienthello_blocked_total` or `tls_clienthello_rejected_total` appears |

### test_openresty_healthz.py

| Test | Validates |
|---|---|
| `test_healthz_endpoint_works` | `/healthz` returns 200 "ok" |

### Test Ordering and Shared State

Tests within each class run sequentially (pytest default). Tests that depend on a clean rate-limit state include `time.sleep(12)` to wait for `block_ttl` expiry (same pattern as APISIX tests). Unlike APISIX tests, **no sleep is needed before metrics assertions** since the metrics endpoint returns live data.

## File Structure

### New Files

| File | Responsibility |
|---|---|
| `integration/openresty-conf/nginx.conf` | OpenResty nginx configuration |
| `integration/openresty-conf/Dockerfile` | OpenResty image: luarocks deps, cert copy, nginx.conf copy |
| `integration/openresty-tests/conftest.py` | pytest fixtures (TLS handshake helper, metrics fetcher) |
| `integration/openresty-tests/test_openresty_tls_rate_limit.py` | TLS rate limiting tests |
| `integration/openresty-tests/test_openresty_metrics.py` | Metrics counter tests |
| `integration/openresty-tests/test_openresty_healthz.py` | Healthz endpoint test |
| `integration/openresty-tests/requirements.txt` | pytest dependencies (same as APISIX tests) |
| `integration/openresty-tests/Dockerfile.test-runner` | Test runner image |
| `docker-compose.openresty-integration.yml` | Compose file for OpenResty integration stack |

### Modified Files

| File | Changes |
|---|---|
| `integration/custom-plugins/tls-clienthello-limiter/adapters/openresty.lua` | Expose `_M.prometheus` for metrics endpoint access |
| `unit/lua/tls-clienthello-limiter/adapters/openresty.lua` | Copy of above for unit test runner |
| `Makefile` | Add `openresty-integration` target, include in `all` |

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
    networks:
      - testnet

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
    networks:
      - testnet

networks:
  testnet:
    driver: bridge
```

Host ports (19443, 19092) are for local debugging only. The test-runner communicates over the Docker network. These stacks are not intended to run concurrently with the APISIX stack (the Makefile runs them sequentially).

## Key Differences from APISIX Tests

1. **No metrics caching** — metrics endpoint returns live data, no sleep needed before metrics assertions (TTL-expiry sleeps still needed for rate limit state)
2. **No APISIX prefix** — metric names are bare (e.g., `tls_clienthello_passed_total` not `apisix_tls_clienthello_passed_total`)
3. **Direct wiring** — `ssl_client_hello_by_lua_block` instead of monkey-patch
4. **Static backend** — `return 200 'ok'` instead of proxying to httpbin
5. **No-SNI test** — validates the `tls_clienthello_no_sni_total` path (not covered in APISIX tests)
