# OpenResty Integration Tests Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add integration tests for the OpenResty adapter, validating all TLS rate limiting decision paths through vanilla OpenResty (no APISIX).

**Architecture:** Two-service Docker Compose stack (openresty + test-runner) mirroring the APISIX integration test pattern. OpenResty serves TLS on port 443 with `ssl_client_hello_by_lua_block` wiring the adapter directly. Tests use the same TLS handshake + metrics assertion approach as APISIX tests, minus metrics-cache sleeps.

**Tech Stack:** OpenResty (openresty/openresty:jammy), nginx-lua-prometheus (luarocks), pytest, pyOpenSSL, Docker Compose

---

## File Structure

### New Files

| File | Responsibility |
|---|---|
| `integration/openresty-conf/nginx.conf` | OpenResty nginx configuration wiring the adapter |
| `integration/openresty-conf/Dockerfile` | OpenResty image: luarocks deps, cert copy, conf copy |
| `integration/openresty-tests/conftest.py` | pytest fixtures (TLS handshake helper, metrics fetcher) |
| `integration/openresty-tests/test_openresty_tls_rate_limit.py` | TLS rate limiting tests (7 tests) |
| `integration/openresty-tests/test_openresty_metrics.py` | Metrics counter tests (2 tests) |
| `integration/openresty-tests/test_openresty_healthz.py` | Healthz endpoint test (1 test) |
| `integration/openresty-tests/requirements.txt` | pytest dependencies (same as APISIX) |
| `integration/openresty-tests/Dockerfile.test-runner` | Test runner image |
| `docker-compose.openresty-integration.yml` | Compose file for OpenResty integration stack |

### Modified Files

| File | Changes |
|---|---|
| `integration/custom-plugins/tls-clienthello-limiter/adapters/openresty.lua` | Expose `_M.prometheus` for metrics endpoint access (1 line) |
| `unit/lua/tls-clienthello-limiter/core.lua` | No change needed. **Spec deviation:** spec lists `unit/lua/.../adapters/openresty.lua` as modified, but this file does not exist — only `core.lua` is copied for unit tests. No unit adapter copy is needed. |
| `Makefile` | Add `openresty-integration` target, include in `all` |

---

## Chunk 1: Adapter Change + OpenResty Container

### Task 1: Expose prometheus instance on the OpenResty adapter

**Files:**
- Modify: `integration/custom-plugins/tls-clienthello-limiter/adapters/openresty.lua:60-81`

- [ ] **Step 1: Add `_M.prometheus` assignment in `init()`**

In `integration/custom-plugins/tls-clienthello-limiter/adapters/openresty.lua`, refactor `_M.init()` to hoist the prometheus variable `p` and expose it as `_M.prometheus`. The original code scopes `p` inside the `else` branch; we hoist it so both paths (caller-provided and auto-discovered) assign to the same variable:

```lua
function _M.init(opts)
    opts = opts or {}

    local p = opts.prometheus
    local metrics_adapter = nil

    if p then
        metrics_adapter = build_metrics_adapter(p, opts.metrics_exptime or 300)
    else
        local ok, prometheus_lib = pcall(require, "prometheus")
        if ok then
            local dict_name = opts.prometheus_dict or "prometheus-metrics"
            p = prometheus_lib.init(dict_name)
            if p then
                metrics_adapter = build_metrics_adapter(p, opts.metrics_exptime or 300)
            end
        end
    end

    _M.prometheus = p  -- expose for metrics endpoint
    opts.metrics = metrics_adapter
    lim = core_mod.new(opts)
end
```

- [ ] **Step 2: Verify unit tests still pass**

Run: `make unit`
Expected: All existing unit tests pass (this change only exposes an already-existing variable)

- [ ] **Step 3: Commit**

```bash
git add integration/custom-plugins/tls-clienthello-limiter/adapters/openresty.lua
git commit -m "feat: expose prometheus instance on OpenResty adapter for metrics endpoint"
```

---

### Task 2: Create nginx.conf for OpenResty

**Files:**
- Create: `integration/openresty-conf/nginx.conf`

- [ ] **Step 1: Write nginx.conf**

```nginx
worker_processes 1;
error_log /dev/stderr info;

events {
    worker_connections 1024;
}

http {
    lua_shared_dict tls-hello-per-ip     1m;
    lua_shared_dict tls-hello-per-domain 1m;
    lua_shared_dict tls-ip-blocklist     1m;
    lua_shared_dict prometheus-metrics   1m;

    lua_package_path "/usr/local/openresty/custom-plugins/?.lua;;";

    init_worker_by_lua_block {
        local adapter = require("tls-clienthello-limiter.adapters.openresty")
        adapter.init({
            per_ip_rate     = 2,
            per_ip_burst    = 4,
            per_domain_rate = 5,
            per_domain_burst = 10,
            block_ttl       = 10,
            prometheus_dict = "prometheus-metrics",
        })
    }

    # HTTPS server — TLS rate limiting endpoint
    server {
        listen 443 ssl;
        server_name test.example.com *.test.example.com;

        ssl_certificate     /etc/nginx/certs/server.crt;
        ssl_certificate_key /etc/nginx/certs/server.key;

        ssl_client_hello_by_lua_block {
            require("tls-clienthello-limiter.adapters.openresty").check()
        }

        location / {
            return 200 'ok';
        }
    }

    # Metrics + healthz server (plain HTTP)
    server {
        listen 9092;
        server_name _;

        location = /healthz {
            access_log off;
            content_by_lua_block {
                ngx.say("ok")
            }
        }

        location = /metrics {
            content_by_lua_block {
                local adapter = require("tls-clienthello-limiter.adapters.openresty")
                if adapter.prometheus then
                    adapter.prometheus:collect()
                else
                    ngx.say("# no prometheus instance")
                end
            }
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add integration/openresty-conf/nginx.conf
git commit -m "feat: add nginx.conf for OpenResty integration tests"
```

---

### Task 3: Create OpenResty Dockerfile

**Files:**
- Create: `integration/openresty-conf/Dockerfile`

- [ ] **Step 1: Write the Dockerfile**

```dockerfile
FROM openresty/openresty:jammy

# Install nginx-lua-prometheus (api7 fork with TTL support)
RUN luarocks install nginx-lua-prometheus

# Copy certs and config
COPY certs/server.crt /etc/nginx/certs/server.crt
COPY certs/server.key /etc/nginx/certs/server.key
COPY openresty-conf/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf

# custom-plugins will be mounted as a volume at runtime
EXPOSE 443 9092

CMD ["openresty", "-g", "daemon off;"]
```

Note: The build context is `integration/`, so paths are relative to that directory.

- [ ] **Step 2: Commit**

```bash
git add integration/openresty-conf/Dockerfile
git commit -m "feat: add Dockerfile for OpenResty integration container"
```

---

### Task 4: Create docker-compose.openresty-integration.yml

**Files:**
- Create: `docker-compose.openresty-integration.yml`

- [ ] **Step 1: Write the compose file**

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

- [ ] **Step 2: Commit**

```bash
git add docker-compose.openresty-integration.yml
git commit -m "feat: add Docker Compose for OpenResty integration tests"
```

---

## Chunk 2: Test Runner + Test Files

### Task 5: Create OpenResty test runner Dockerfile and requirements

**Files:**
- Create: `integration/openresty-tests/requirements.txt`
- Create: `integration/openresty-tests/Dockerfile.test-runner`

- [ ] **Step 1: Write requirements.txt**

```
pytest>=8.0
requests>=2.31
pyOpenSSL>=24.0
```

Same dependencies as APISIX tests.

- [ ] **Step 2: Write Dockerfile.test-runner**

```dockerfile
FROM python:3.12-slim

COPY openresty-tests/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

WORKDIR /tests
COPY openresty-tests/ /tests/
COPY certs/ /certs/

CMD ["pytest", "-v", "--tb=short", "/tests/"]
```

Note: Build context is `integration/`, so paths reference `openresty-tests/` not `tests/`.

- [ ] **Step 3: Commit**

```bash
git add integration/openresty-tests/requirements.txt integration/openresty-tests/Dockerfile.test-runner
git commit -m "feat: add test runner Dockerfile and requirements for OpenResty tests"
```

---

### Task 6: Create conftest.py for OpenResty tests

**Files:**
- Create: `integration/openresty-tests/conftest.py`

This mirrors `integration/tests/conftest.py` but uses OpenResty environment variables and has a `do_tls_handshake` fixture that supports no-SNI (passing `sni=None`).

- [ ] **Step 1: Write conftest.py**

```python
import os
import ssl
import socket

import pytest
import requests


OPENRESTY_HTTPS_HOST = os.environ.get("OPENRESTY_HTTPS_HOST", "openresty")
OPENRESTY_HTTPS_PORT = int(os.environ.get("OPENRESTY_HTTPS_PORT", "443"))
OPENRESTY_METRICS_URL = os.environ.get(
    "OPENRESTY_METRICS_URL", "http://openresty:9092/metrics"
)
TEST_DOMAIN = os.environ.get("TEST_DOMAIN", "test.example.com")
CERT_PATH = "/certs/server.crt"


@pytest.fixture(scope="session")
def openresty_https_host():
    return OPENRESTY_HTTPS_HOST


@pytest.fixture(scope="session")
def openresty_https_port():
    return OPENRESTY_HTTPS_PORT


@pytest.fixture(scope="session")
def metrics_url():
    return OPENRESTY_METRICS_URL


@pytest.fixture(scope="session")
def test_domain():
    return TEST_DOMAIN


def tls_handshake(host, port, sni, timeout=5):
    """Perform a TLS handshake and return True on success, False on failure.

    If sni is None, performs handshake without SNI extension.
    """
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    ssl_sock = ctx.wrap_socket(sock, server_hostname=sni)
    try:
        ssl_sock.connect((host, port))
        return True
    except (ssl.SSLError, ConnectionResetError, ConnectionRefusedError, OSError):
        return False
    finally:
        ssl_sock.close()


@pytest.fixture(scope="session")
def do_tls_handshake(openresty_https_host, openresty_https_port):
    """Returns a callable that performs a TLS handshake to OpenResty.

    Pass sni=None for no-SNI handshake.
    """
    def _handshake(sni=TEST_DOMAIN, timeout=5):
        return tls_handshake(openresty_https_host, openresty_https_port, sni, timeout=timeout)
    return _handshake


def fetch_metrics(url=None):
    """Fetch and return the raw metrics text from the prometheus endpoint."""
    resp = requests.get(url or OPENRESTY_METRICS_URL, timeout=5)
    resp.raise_for_status()
    return resp.text


@pytest.fixture
def get_metrics(metrics_url):
    """Returns a callable that fetches metrics text."""
    def _fetch():
        return fetch_metrics(metrics_url)
    return _fetch
```

Key differences from APISIX conftest.py:
- Environment variables: `OPENRESTY_HTTPS_HOST`, `OPENRESTY_HTTPS_PORT`, `OPENRESTY_METRICS_URL`
- `tls_handshake()` accepts `sni=None` to skip SNI extension (Python's `ssl.wrap_socket` with `server_hostname=None` omits the SNI extension)
- No `apisix_http_url` fixture (not needed — no HTTP upstream)

- [ ] **Step 2: Commit**

```bash
git add integration/openresty-tests/conftest.py
git commit -m "feat: add conftest.py for OpenResty integration tests"
```

---

### Task 7: Create test_openresty_healthz.py

**Files:**
- Create: `integration/openresty-tests/test_openresty_healthz.py`

- [ ] **Step 1: Write the healthz test**

```python
"""Integration test for the OpenResty healthz endpoint (Docker healthcheck)."""

import os

import requests


class TestHealthz:
    def test_healthz_endpoint_works(self):
        """The /healthz endpoint (used for Docker healthcheck) should respond."""
        host = os.environ.get("OPENRESTY_HTTPS_HOST", "openresty")
        healthz_url = f"http://{host}:9092/healthz"
        resp = requests.get(healthz_url, timeout=5)
        assert resp.status_code == 200
        assert resp.text.strip() == "ok"
```

- [ ] **Step 2: Commit**

```bash
git add integration/openresty-tests/test_openresty_healthz.py
git commit -m "test: add healthz endpoint test for OpenResty"
```

---

### Task 8: Create test_openresty_tls_rate_limit.py

**Files:**
- Create: `integration/openresty-tests/test_openresty_tls_rate_limit.py`

This mirrors `integration/tests/test_tls_rate_limit.py` with two key differences:
1. No metrics-cache sleep (live metrics endpoint)
2. Added no-SNI test

- [ ] **Step 1: Write the rate limit tests**

```python
"""Integration tests for TLS ClientHello rate limiting via OpenResty adapter."""

import time


class TestTlsPerIpRateLimit:
    def test_normal_handshake_succeeds(self, do_tls_handshake):
        """A single TLS handshake should succeed."""
        assert do_tls_handshake() is True

    def test_rapid_handshakes_get_rejected(self, do_tls_handshake):
        """Flooding TLS handshakes beyond per_ip_rate+burst should fail.

        Config: per_ip_rate=2, per_ip_burst=4.
        The leaky bucket allows rate+burst=6 before rejecting.
        We send 20 rapid handshakes and expect some to fail.
        """
        results = []
        for _ in range(20):
            results.append(do_tls_handshake(timeout=2))

        successes = sum(1 for r in results if r)
        failures = sum(1 for r in results if not r)

        assert successes > 0, "Expected at least some successful handshakes"
        assert failures > 0, "Expected at least some rejected handshakes"

    def test_rejected_ip_gets_auto_blocked(self, do_tls_handshake, get_metrics):
        """After rejection, the IP should be auto-blocked.

        The tls_ip_autoblock_total counter should increment.
        No sleep needed — OpenResty metrics are live (no caching).
        """
        for _ in range(30):
            do_tls_handshake(timeout=1)

        metrics = get_metrics()
        assert "tls_ip_autoblock_total" in metrics or "tls_clienthello_rejected_total" in metrics

    def test_blocked_handshakes_fail_immediately(self, do_tls_handshake):
        """Once IP is blocked, handshakes should fail immediately."""
        for _ in range(30):
            do_tls_handshake(timeout=1)

        time.sleep(0.5)
        results = [do_tls_handshake(timeout=2) for _ in range(5)]
        failures = sum(1 for r in results if not r)
        assert failures >= 3, f"Expected mostly failures after block, got {failures}/5"

    def test_block_expires_after_ttl(self, do_tls_handshake):
        """After block_ttl (10s), the IP should be unblocked."""
        for _ in range(30):
            do_tls_handshake(timeout=1)

        time.sleep(12)

        assert do_tls_handshake() is True


class TestTlsPerDomainRateLimit:
    def test_per_domain_limit_triggers(self, do_tls_handshake, get_metrics):
        """Flooding a single domain should trigger per-domain rejection.

        Config: per_domain_rate=5, per_domain_burst=10.
        """
        # Wait for any previous per-IP block to clear
        time.sleep(12)

        for _ in range(30):
            do_tls_handshake(sni="test.example.com", timeout=1)

        metrics = get_metrics()
        assert "tls_clienthello_rejected_total" in metrics


class TestTlsNoSni:
    def test_no_sni_handshake_passes(self, do_tls_handshake, get_metrics):
        """TLS handshake without SNI extension should succeed and emit no-SNI metric.

        When server_hostname=None, SSLContext.wrap_socket() omits the SNI extension.
        The adapter should allow the handshake and increment tls_clienthello_no_sni_total.
        """
        # Wait for any previous per-IP block to clear
        time.sleep(12)

        result = do_tls_handshake(sni=None)
        assert result is True, "No-SNI handshake should succeed"

        metrics = get_metrics()
        assert "tls_clienthello_no_sni_total" in metrics
```

- [ ] **Step 2: Commit**

```bash
git add integration/openresty-tests/test_openresty_tls_rate_limit.py
git commit -m "test: add TLS rate limiting tests for OpenResty adapter"
```

---

### Task 9: Create test_openresty_metrics.py

**Files:**
- Create: `integration/openresty-tests/test_openresty_metrics.py`

- [ ] **Step 1: Write the metrics tests**

```python
"""Integration tests for OpenResty prometheus metrics endpoint."""

import time


class TestOpenrestyMetrics:
    def test_passed_counter_increments(self, do_tls_handshake, get_metrics):
        """Successful handshakes should increment passed counter.

        No apisix_ prefix — bare metric names from nginx-lua-prometheus.
        """
        # Wait for any blocks to expire
        time.sleep(12)

        do_tls_handshake()
        metrics = get_metrics()
        assert "tls_clienthello_passed_total" in metrics

    def test_blocked_counter_increments(self, do_tls_handshake, get_metrics):
        """After flooding, blocked/rejected counter should appear."""
        for _ in range(30):
            do_tls_handshake(timeout=1)

        metrics = get_metrics()
        assert ("tls_clienthello_blocked_total" in metrics
                or "tls_clienthello_rejected_total" in metrics)
```

- [ ] **Step 2: Commit**

```bash
git add integration/openresty-tests/test_openresty_metrics.py
git commit -m "test: add metrics counter tests for OpenResty adapter"
```

---

## Chunk 3: Makefile + Integration Smoke Test

### Task 10: Add Makefile target for OpenResty integration tests

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: Add `openresty-integration` target and update `all` and `clean`**

Current `Makefile` (for reference):
```makefile
.PHONY: unit integration certs all clean

all: unit integration
```

Updated `Makefile`:
```makefile
.PHONY: unit integration openresty-integration certs all clean

all: unit integration openresty-integration

unit:
	docker compose -f docker-compose.unit.yml up --build --abort-on-container-exit --exit-code-from unit-tests
	docker compose -f docker-compose.unit.yml down -v

certs: integration/certs/server.crt

integration/certs/server.crt:
	bash integration/generate-conf.sh

integration: certs
	docker compose -f docker-compose.integration.yml up --build --abort-on-container-exit --exit-code-from test-runner
	docker compose -f docker-compose.integration.yml down -v

openresty-integration: certs
	docker compose -f docker-compose.openresty-integration.yml up --build --abort-on-container-exit --exit-code-from test-runner
	docker compose -f docker-compose.openresty-integration.yml down -v

clean:
	docker compose -f docker-compose.unit.yml down -v 2>/dev/null || true
	docker compose -f docker-compose.integration.yml down -v 2>/dev/null || true
	docker compose -f docker-compose.openresty-integration.yml down -v 2>/dev/null || true
	rm -f integration/certs/server.crt integration/certs/server.key integration/conf/apisix.yaml
```

- [ ] **Step 2: Commit**

```bash
git add Makefile
git commit -m "feat: add openresty-integration Makefile target"
```

---

### Task 11: Run the OpenResty integration tests

- [ ] **Step 1: Generate certs if needed**

Run: `make certs`

- [ ] **Step 2: Run the OpenResty integration tests**

Run: `make openresty-integration`
Expected: All 10 tests pass (7 rate limit + 2 metrics + 1 healthz)

- [ ] **Step 3: Fix any failures**

If tests fail, check:
1. OpenResty container logs: `docker compose -f docker-compose.openresty-integration.yml logs openresty`
2. nginx.conf syntax: the Lua blocks must load correctly
3. Metrics endpoint: `curl http://localhost:19092/metrics` (host port mapping)
4. TLS: `openssl s_client -connect localhost:19443 -servername test.example.com`

- [ ] **Step 4: Run all tests to verify nothing broke**

Run: `make all`
Expected: Unit tests pass, APISIX integration tests pass, OpenResty integration tests pass (sequential)

- [ ] **Step 5: Commit any fixes**

```bash
git add -A
git commit -m "fix: address OpenResty integration test issues"
```

(Only if fixes were needed)

---

### Task 12: Final cleanup commit

- [ ] **Step 1: Verify clean working tree**

Run: `git status`
Expected: Clean working tree, no untracked files

- [ ] **Step 2: Use @superpowers:verification-before-completion to verify all tests pass**

- [ ] **Step 3: Use @superpowers:finishing-a-development-branch to wrap up**
