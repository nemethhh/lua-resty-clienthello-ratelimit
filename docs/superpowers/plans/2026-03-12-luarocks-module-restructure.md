# LuaRocks Module Restructure Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the test-harness repo into a publishable `lua-resty-clienthello-ratelimit` LuaRocks package with `lib/`, `t/`, and `examples/` layout.

**Architecture:** Move Lua source to `lib/resty/clienthello/ratelimit/`, tests to `t/{unit,integration,openresty-integration}/`, examples to `examples/`. All Dockerfiles switch from `lua_package_path` hacks to `luarocks make` for module installation. No logic changes — purely structural.

**Tech Stack:** Lua/OpenResty, LuaRocks, Docker, docker-compose, busted (unit), pytest (integration)

**Spec:** `docs/superpowers/specs/2026-03-12-luarocks-module-restructure-design.md`

---

## File Structure

### New files to create

| Path | Responsibility |
|---|---|
| `lua-resty-clienthello-ratelimit-0.1.0-1.rockspec` | LuaRocks package definition |
| `lib/resty/clienthello/ratelimit/init.lua` | Core rate limiter (from `integration/custom-plugins/tls-clienthello-limiter/core.lua`) |
| `lib/resty/clienthello/ratelimit/openresty.lua` | OpenResty adapter (from `integration/custom-plugins/tls-clienthello-limiter/adapters/openresty.lua`) |
| `lib/resty/clienthello/ratelimit/apisix.lua` | APISIX adapter (from `integration/custom-plugins/tls-clienthello-limiter/adapters/apisix.lua`) |
| `examples/apisix-plugin-shim.lua` | Example APISIX plugin shim |
| `examples/nginx.conf` | Example OpenResty nginx.conf |
| `examples/apisix-config.yaml` | Example APISIX config |
| `t/unit/Dockerfile` | Unit test container (luarocks make) |
| `t/unit/spec/helpers.lua` | Unit test ngx mocks (updated require paths) |
| `t/unit/spec/core_helpers.lua` | Unit test core mocks (updated require paths) |
| `t/unit/spec/tls_limiter_core_spec.lua` | Unit test spec (unchanged logic) |
| `t/integration/Dockerfile.apisix` | Custom APISIX image with luarocks make |
| `t/integration/Dockerfile.test-runner` | APISIX test runner (updated COPY paths) |
| `t/integration/generate-conf.sh` | Cert/config generator (updated paths) |
| `t/integration/conf/config.yaml` | APISIX config (unchanged) |
| `t/integration/conf/apisix.yaml.tpl` | APISIX route template (unchanged) |
| `t/integration/custom-plugins/apisix/plugins/tls-clienthello-limiter.lua` | Plugin shim (updated require) |
| `t/integration/tests/conftest.py` | APISIX test fixtures (unchanged) |
| `t/integration/tests/test_healthz.py` | APISIX healthz test (unchanged) |
| `t/integration/tests/test_tls_rate_limit.py` | APISIX rate limit tests (unchanged) |
| `t/integration/tests/requirements.txt` | APISIX test deps (unchanged) |
| `t/openresty-integration/conf/Dockerfile` | OpenResty container (luarocks make, no volume mounts) |
| `t/openresty-integration/conf/nginx.conf` | OpenResty config (updated require paths) |
| `t/openresty-integration/Dockerfile.test-runner` | OpenResty test runner (updated COPY paths) |
| `t/openresty-integration/tests/conftest.py` | OpenResty test fixtures (unchanged) |
| `t/openresty-integration/tests/test_openresty_healthz.py` | OpenResty healthz test (unchanged) |
| `t/openresty-integration/tests/test_openresty_tls_rate_limit.py` | OpenResty rate limit tests (unchanged) |
| `t/openresty-integration/tests/test_openresty_metrics.py` | OpenResty metrics tests (unchanged) |
| `t/openresty-integration/tests/requirements.txt` | OpenResty test deps (unchanged) |

### Files to modify in-place

| Path | Change |
|---|---|
| `docker-compose.unit.yml` | Build context → `.`, dockerfile → `t/unit/Dockerfile` |
| `docker-compose.integration.yml` | APISIX: custom build from Dockerfile.apisix; test-runner: new paths |
| `docker-compose.openresty-integration.yml` | Build context → `.`; remove custom-plugins volume; new paths |
| `Makefile` | Update certs target path, clean paths |
| `.gitignore` | Update cert/config paths to `t/integration/...` |

### Files to delete

| Path | Reason |
|---|---|
| `unit/` (entire tree) | Moved to `t/unit/`; `unit/lua/` duplicate eliminated |
| `integration/` (entire tree) | Source → `lib/`, tests → `t/`, shim → `examples/` |

---

## Chunk 1: Foundation — Rockspec and lib/

### Task 1: Create rockspec

**Files:**
- Create: `lua-resty-clienthello-ratelimit-0.1.0-1.rockspec`

- [ ] **Step 1: Create the rockspec file**

```lua
package = "lua-resty-clienthello-ratelimit"
version = "0.1.0-1"

source = {
    url = "git+https://github.com/<owner>/lua-resty-clienthello-ratelimit.git",
    tag = "v0.1.0",
}

description = {
    summary = "Three-tier TLS ClientHello rate limiter for OpenResty and APISIX",
    detailed = [[
        Rate limits TLS ClientHello requests using a three-tier approach:
        IP blocklist (T0), per-IP leaky bucket (T1), and per-SNI leaky bucket (T2).
        Ships with adapters for vanilla OpenResty and Apache APISIX.
    ]],
    homepage = "https://github.com/<owner>/lua-resty-clienthello-ratelimit",
    license = "MIT",
}

dependencies = {
    "lua >= 5.1",
}

build = {
    type = "builtin",
    modules = {
        ["resty.clienthello.ratelimit"]            = "lib/resty/clienthello/ratelimit/init.lua",
        ["resty.clienthello.ratelimit.openresty"]  = "lib/resty/clienthello/ratelimit/openresty.lua",
        ["resty.clienthello.ratelimit.apisix"]     = "lib/resty/clienthello/ratelimit/apisix.lua",
    },
}
```

- [ ] **Step 2: Commit**

```bash
git add lua-resty-clienthello-ratelimit-0.1.0-1.rockspec
git commit -m "feat: add LuaRocks rockspec for lua-resty-clienthello-ratelimit"
```

### Task 2: Create lib/ with updated require paths

**Files:**
- Create: `lib/resty/clienthello/ratelimit/init.lua`
- Create: `lib/resty/clienthello/ratelimit/openresty.lua`
- Create: `lib/resty/clienthello/ratelimit/apisix.lua`

- [ ] **Step 1: Create init.lua (core)**

Copy `integration/custom-plugins/tls-clienthello-limiter/core.lua` to `lib/resty/clienthello/ratelimit/init.lua`.

Update the module header comment — change the `require()` example in the usage block:

```lua
-- Usage:
--   local limiter = require("resty.clienthello.ratelimit")
```

No other changes. The core has no internal `require()` calls to update — it only requires `resty.limit.req`, `ngx.ssl.clienthello`, `ffi`, and `resty.core.base` which are all external.

- [ ] **Step 2: Create openresty.lua adapter**

Copy `integration/custom-plugins/tls-clienthello-limiter/adapters/openresty.lua` to `lib/resty/clienthello/ratelimit/openresty.lua`.

One require path change on line 12:

```lua
-- Old:
local core_mod = require("tls-clienthello-limiter.core")
-- New:
local core_mod = require("resty.clienthello.ratelimit")
```

- [ ] **Step 3: Create apisix.lua adapter**

Copy `integration/custom-plugins/tls-clienthello-limiter/adapters/apisix.lua` to `lib/resty/clienthello/ratelimit/apisix.lua`.

One require path change on line 8:

```lua
-- Old:
local core_mod = require("tls-clienthello-limiter.core")
-- New:
local core_mod = require("resty.clienthello.ratelimit")
```

- [ ] **Step 4: Commit**

```bash
git add lib/
git commit -m "feat: add lib/ with core and adapters using resty.clienthello.ratelimit paths"
```

---

## Chunk 2: Unit Tests — t/unit/

### Task 3: Move unit test specs to t/unit/

**Files:**
- Create: `t/unit/spec/helpers.lua`
- Create: `t/unit/spec/core_helpers.lua`
- Create: `t/unit/spec/tls_limiter_core_spec.lua`

- [ ] **Step 1: Create t/unit/spec/helpers.lua**

Copy `unit/spec/helpers.lua` to `t/unit/spec/helpers.lua`.

Two changes to the `setup()` function (around line 135-137):

```lua
-- Old (line 135):
    package.loaded["custom-metrics"] = nil
    package.loaded["tls-clienthello-limiter.core"] = nil
-- New:
    package.loaded["resty.clienthello.ratelimit"] = nil
```

The `"custom-metrics"` line is removed entirely (dead reference per spec). The core module path is updated.

- [ ] **Step 2: Create t/unit/spec/core_helpers.lua**

Copy `unit/spec/core_helpers.lua` to `t/unit/spec/core_helpers.lua`.

Two changes:

Line 34 — clear the new module path instead of old:
```lua
-- Old:
    package.loaded["tls-clienthello-limiter.core"] = nil
-- New:
    package.loaded["resty.clienthello.ratelimit"] = nil
```

Line 74 in `require_core()` — require the new path:
```lua
-- Old:
    local core = require("tls-clienthello-limiter.core")
-- New:
    local core = require("resty.clienthello.ratelimit")
```

- [ ] **Step 3: Create t/unit/spec/tls_limiter_core_spec.lua**

Copy `unit/spec/tls_limiter_core_spec.lua` to `t/unit/spec/tls_limiter_core_spec.lua` **unchanged**. The spec file only uses `require("spec.core_helpers")` which resolves via busted's working directory — no path changes needed.

- [ ] **Step 4: Commit**

```bash
git add t/unit/spec/
git commit -m "feat: add unit test specs under t/unit/ with updated require paths"
```

### Task 4: Create unit test Dockerfile and update docker-compose

**Files:**
- Create: `t/unit/Dockerfile`
- Modify: `docker-compose.unit.yml`

- [ ] **Step 1: Create t/unit/Dockerfile**

This replaces the old `unit/Dockerfile`. Key change: uses `luarocks make` instead of `LUA_PATH` hack. No more `lua/` directory copy.

```dockerfile
FROM openresty/openresty:jammy

RUN luarocks install busted

COPY . /src
WORKDIR /src
RUN luarocks make

WORKDIR /src/t/unit
CMD ["busted", "--verbose", "spec/"]
```

- [ ] **Step 2: Update docker-compose.unit.yml**

Build context changes to repo root so rockspec + lib/ are available:

```yaml
services:
  unit-tests:
    build:
      context: .
      dockerfile: t/unit/Dockerfile
```

- [ ] **Step 3: Run unit tests to verify**

```bash
make unit
```

Expected: All tests pass. The module is installed via `luarocks make` and busted finds specs in `t/unit/spec/`.

- [ ] **Step 4: Commit**

```bash
git add t/unit/Dockerfile docker-compose.unit.yml
git commit -m "feat: add unit Dockerfile with luarocks make, update compose"
```

---

## Chunk 3: APISIX Integration Tests — t/integration/

### Task 5: Move APISIX integration test infrastructure

**Files:**
- Create: `t/integration/generate-conf.sh`
- Create: `t/integration/conf/config.yaml` (copy unchanged)
- Create: `t/integration/conf/apisix.yaml.tpl` (copy unchanged)
- Create: `t/integration/custom-plugins/apisix/plugins/tls-clienthello-limiter.lua`

- [ ] **Step 1: Create t/integration/generate-conf.sh**

Copy `integration/generate-conf.sh` to `t/integration/generate-conf.sh`. The script uses `$(dirname "$0")` for relative paths, so it auto-adapts to its new location. **No changes needed** — `CERTS_DIR` resolves to `t/integration/certs` and `CONF_DIR` to `t/integration/conf`.

- [ ] **Step 2: Copy config files unchanged**

```bash
mkdir -p t/integration/conf
cp integration/conf/config.yaml t/integration/conf/config.yaml
cp integration/conf/apisix.yaml.tpl t/integration/conf/apisix.yaml.tpl
```

These files need no changes — the `extra_lua_path` in config.yaml stays the same since the shim still lives at `custom-plugins/apisix/plugins/...` inside the container.

- [ ] **Step 3: Create the APISIX plugin shim with updated require**

Create `t/integration/custom-plugins/apisix/plugins/tls-clienthello-limiter.lua`:

```lua
-- Shim: APISIX plugin loader expects apisix.plugins.<name>
-- Delegates to the LuaRocks-installed adapter module
local adapter = require("resty.clienthello.ratelimit.apisix")
return adapter
```

- [ ] **Step 4: Commit**

```bash
git add t/integration/generate-conf.sh t/integration/conf/ t/integration/custom-plugins/
git commit -m "feat: add APISIX integration config and shim under t/integration/"
```

### Task 6: Move APISIX integration test files and Dockerfiles

**Files:**
- Create: `t/integration/tests/conftest.py` (copy unchanged)
- Create: `t/integration/tests/test_healthz.py` (copy unchanged)
- Create: `t/integration/tests/test_tls_rate_limit.py` (copy unchanged)
- Create: `t/integration/tests/requirements.txt` (copy unchanged)
- Create: `t/integration/Dockerfile.apisix`
- Create: `t/integration/Dockerfile.test-runner`

- [ ] **Step 1: Copy test files unchanged**

```bash
mkdir -p t/integration/tests
cp integration/tests/conftest.py t/integration/tests/conftest.py
cp integration/tests/test_healthz.py t/integration/tests/test_healthz.py
cp integration/tests/test_tls_rate_limit.py t/integration/tests/test_tls_rate_limit.py
cp integration/tests/requirements.txt t/integration/tests/requirements.txt
```

No changes to any Python test file — they use environment variables for URLs/ports, not file paths.

- [ ] **Step 2: Create t/integration/Dockerfile.apisix**

New file — builds custom APISIX image with `luarocks make`:

```dockerfile
FROM apache/apisix:3.15.0-ubuntu
COPY . /src
RUN cd /src && luarocks make
```

- [ ] **Step 3: Create t/integration/Dockerfile.test-runner**

Updated COPY paths since build context is now repo root:

```dockerfile
FROM python:3.12-slim

COPY t/integration/tests/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

WORKDIR /tests
COPY t/integration/tests/ /tests/
COPY t/integration/certs/ /certs/

CMD ["pytest", "-v", "--tb=short", "/tests/"]
```

- [ ] **Step 4: Update docker-compose.integration.yml**

```yaml
services:
  httpbin:
    image: ghcr.io/mccutchen/go-httpbin
    networks:
      - testnet

  apisix:
    build:
      context: .
      dockerfile: t/integration/Dockerfile.apisix
    volumes:
      - ./t/integration/conf/config.yaml:/usr/local/apisix/conf/config.yaml:ro
      - ./t/integration/conf/apisix.yaml:/usr/local/apisix/conf/apisix.yaml:ro
      - ./t/integration/custom-plugins:/usr/local/apisix/custom-plugins:ro
    ports:
      - "9080:80"
      - "9443:443"
      - "9091:9091"
      - "9092:9092"
    depends_on:
      - httpbin
    healthcheck:
      test: ["CMD-SHELL", "bash -c 'echo > /dev/tcp/127.0.0.1/9092'"]
      interval: 2s
      timeout: 2s
      retries: 30
    networks:
      - testnet

  test-runner:
    build:
      context: .
      dockerfile: t/integration/Dockerfile.test-runner
    depends_on:
      apisix:
        condition: service_healthy
    environment:
      APISIX_HTTP_URL: "http://apisix:80"
      APISIX_HTTPS_HOST: "apisix"
      APISIX_HTTPS_PORT: "443"
      APISIX_METRICS_URL: "http://apisix:9091/apisix/prometheus/metrics"
      TEST_DOMAIN: "test.example.com"
    networks:
      - testnet

networks:
  testnet:
    driver: bridge
```

Key changes from current:
- `apisix` service: `build:` block replaces `image:` — uses custom Dockerfile.apisix
- `apisix` volumes: paths prefixed with `./t/integration/`
- `test-runner` build context: `.` with `t/integration/Dockerfile.test-runner`

- [ ] **Step 5: Run APISIX integration tests to verify**

```bash
make certs && make integration
```

Expected: `make certs` runs `bash t/integration/generate-conf.sh` (requires Makefile update from Task 9 — if not yet done, run manually: `bash t/integration/generate-conf.sh`). All APISIX integration tests pass.

**Note:** If running before Makefile is updated, generate certs manually:
```bash
bash t/integration/generate-conf.sh
docker compose -f docker-compose.integration.yml up --build --abort-on-container-exit --exit-code-from test-runner
docker compose -f docker-compose.integration.yml down -v
```

- [ ] **Step 6: Commit**

```bash
git add t/integration/tests/ t/integration/Dockerfile.apisix t/integration/Dockerfile.test-runner docker-compose.integration.yml
git commit -m "feat: move APISIX integration tests to t/integration/, add custom Dockerfile"
```

---

## Chunk 4: OpenResty Integration Tests — t/openresty-integration/

### Task 7: Move OpenResty integration test infrastructure

**Files:**
- Create: `t/openresty-integration/conf/Dockerfile`
- Create: `t/openresty-integration/conf/nginx.conf`
- Create: `t/openresty-integration/Dockerfile.test-runner`
- Create: `t/openresty-integration/tests/conftest.py` (copy unchanged)
- Create: `t/openresty-integration/tests/test_openresty_healthz.py` (copy unchanged)
- Create: `t/openresty-integration/tests/test_openresty_tls_rate_limit.py` (copy unchanged)
- Create: `t/openresty-integration/tests/test_openresty_metrics.py` (copy unchanged)
- Create: `t/openresty-integration/tests/requirements.txt` (copy unchanged)

- [ ] **Step 1: Create t/openresty-integration/conf/Dockerfile**

Build context is repo root. Uses `luarocks make` instead of volume-mounted custom-plugins:

```dockerfile
FROM openresty/openresty:jammy

RUN luarocks install nginx-lua-prometheus

COPY . /src
RUN cd /src && luarocks make

COPY t/integration/certs/server.crt /etc/nginx/certs/server.crt
COPY t/integration/certs/server.key /etc/nginx/certs/server.key
COPY t/openresty-integration/conf/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf

EXPOSE 443 9092
CMD ["openresty", "-g", "daemon off;"]
```

Key differences from old `integration/openresty-conf/Dockerfile`:
- `COPY . /src` + `RUN cd /src && luarocks make` installs module system-wide
- Cert paths: `t/integration/certs/` (shared certs, single source)
- Config path: `t/openresty-integration/conf/nginx.conf`
- No custom-plugins volume mount needed at runtime

- [ ] **Step 2: Create t/openresty-integration/conf/nginx.conf**

Copy `integration/openresty-conf/nginx.conf` with two require path updates and removal of `lua_package_path`:

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

    init_worker_by_lua_block {
        local adapter = require("resty.clienthello.ratelimit.openresty")
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
            require("resty.clienthello.ratelimit.openresty").check()
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
                local adapter = require("resty.clienthello.ratelimit.openresty")
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

Changes from original:
- Removed: `lua_package_path "/usr/local/openresty/custom-plugins/?.lua;;";` (line 14 of old file — module is now installed via LuaRocks)
- Line 17: `require("tls-clienthello-limiter.adapters.openresty")` → `require("resty.clienthello.ratelimit.openresty")`
- Line 37: same require path update
- Line 59: same require path update

- [ ] **Step 3: Create t/openresty-integration/Dockerfile.test-runner**

```dockerfile
FROM python:3.12-slim

COPY t/openresty-integration/tests/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

WORKDIR /tests
COPY t/openresty-integration/tests/ /tests/
COPY t/integration/certs/ /certs/

CMD ["pytest", "-v", "--tb=short", "/tests/"]
```

Key change: certs come from `t/integration/certs/` (shared source).

- [ ] **Step 4: Copy test files unchanged**

```bash
mkdir -p t/openresty-integration/tests
cp integration/openresty-tests/conftest.py t/openresty-integration/tests/conftest.py
cp integration/openresty-tests/test_openresty_healthz.py t/openresty-integration/tests/test_openresty_healthz.py
cp integration/openresty-tests/test_openresty_tls_rate_limit.py t/openresty-integration/tests/test_openresty_tls_rate_limit.py
cp integration/openresty-tests/test_openresty_metrics.py t/openresty-integration/tests/test_openresty_metrics.py
cp integration/openresty-tests/requirements.txt t/openresty-integration/tests/requirements.txt
```

No changes — Python tests use environment variables, not file paths.

- [ ] **Step 5: Update docker-compose.openresty-integration.yml**

```yaml
services:
  openresty:
    build:
      context: .
      dockerfile: t/openresty-integration/conf/Dockerfile
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
      context: .
      dockerfile: t/openresty-integration/Dockerfile.test-runner
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

Key changes from current:
- `openresty` build context: `.` with `t/openresty-integration/conf/Dockerfile`
- `openresty` volumes: **removed entirely** (no more custom-plugins mount — module installed via luarocks make)
- `test-runner` build context: `.` with `t/openresty-integration/Dockerfile.test-runner`

- [ ] **Step 6: Run OpenResty integration tests to verify**

```bash
docker compose -f docker-compose.openresty-integration.yml up --build --abort-on-container-exit --exit-code-from test-runner
docker compose -f docker-compose.openresty-integration.yml down -v
```

Expected: All OpenResty integration tests pass. Certs must already exist in `t/integration/certs/` from Task 6.

- [ ] **Step 7: Commit**

```bash
git add t/openresty-integration/ docker-compose.openresty-integration.yml
git commit -m "feat: move OpenResty integration tests to t/openresty-integration/, use luarocks make"
```

---

## Chunk 5: Cleanup — Examples, Makefile, .gitignore, Delete Old

### Task 8: Create examples/

**Files:**
- Create: `examples/apisix-plugin-shim.lua`
- Create: `examples/nginx.conf`
- Create: `examples/apisix-config.yaml`

- [ ] **Step 1: Create examples/apisix-plugin-shim.lua**

```lua
-- Example APISIX plugin shim
-- Place this file at: apisix/plugins/tls-clienthello-limiter.lua
local adapter = require("resty.clienthello.ratelimit.apisix")
return adapter
```

- [ ] **Step 2: Create examples/nginx.conf**

Minimal OpenResty example showing the three integration points. Copy `t/openresty-integration/conf/nginx.conf` as-is — it's already a working minimal config with the new require paths.

- [ ] **Step 3: Create examples/apisix-config.yaml**

Minimal APISIX config showing the key plugin settings. Extract the relevant sections from `t/integration/conf/config.yaml`:

```yaml
# Example APISIX config for tls-clienthello-limiter
# Add these sections to your existing apisix config.yaml

apisix:
  extra_lua_path: "/path/to/custom-plugins/?.lua"

plugins:
  - tls-clienthello-limiter
  # ... your other plugins ...

nginx_config:
  http:
    custom_lua_shared_dict:
      tls-hello-per-ip: 1m
      tls-hello-per-domain: 1m
      tls-ip-blocklist: 1m

plugin_attr:
  tls-clienthello-limiter:
    per_ip_rate: 2
    per_ip_burst: 4
    per_domain_rate: 5
    per_domain_burst: 10
    block_ttl: 10
```

- [ ] **Step 4: Commit**

```bash
git add examples/
git commit -m "docs: add examples/ with APISIX and OpenResty config samples"
```

### Task 9: Update Makefile and .gitignore

**Files:**
- Modify: `Makefile`
- Modify: `.gitignore`

- [ ] **Step 1: Update Makefile**

```makefile
.PHONY: unit integration openresty-integration certs all clean

all: unit integration openresty-integration

unit:
	docker compose -f docker-compose.unit.yml up --build --abort-on-container-exit --exit-code-from unit-tests
	docker compose -f docker-compose.unit.yml down -v

certs: t/integration/certs/server.crt

t/integration/certs/server.crt:
	bash t/integration/generate-conf.sh

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
	rm -f t/integration/certs/server.crt t/integration/certs/server.key t/integration/conf/apisix.yaml
```

Changes: `certs` target and `clean` paths updated from `integration/...` to `t/integration/...`.

- [ ] **Step 2: Update .gitignore**

```gitignore
t/integration/certs/server.crt
t/integration/certs/server.key
t/integration/conf/apisix.yaml
__pycache__/
*.pyc
.pytest_cache/
.worktrees/
reference/
```

Only change: cert/config paths updated from `integration/...` to `t/integration/...`.

- [ ] **Step 3: Commit**

```bash
git add Makefile .gitignore
git commit -m "chore: update Makefile and .gitignore for new t/ layout"
```

### Task 10: Delete old directories

**Files:**
- Delete: `unit/` (entire tree)
- Delete: `integration/` (entire tree)

- [ ] **Step 1: Verify all three test suites pass with new structure**

```bash
make all
```

Expected: `unit`, `integration`, and `openresty-integration` all pass. This is the gate check before deleting old files.

- [ ] **Step 2: Delete old unit/ directory**

```bash
git rm -r unit/
```

This removes:
- `unit/Dockerfile` (replaced by `t/unit/Dockerfile`)
- `unit/lua/tls-clienthello-limiter/core.lua` (duplicate eliminated — module installed via luarocks)
- `unit/spec/` (moved to `t/unit/spec/`)

- [ ] **Step 3: Delete old integration/ directory**

```bash
git rm -r integration/
```

This removes:
- `integration/custom-plugins/` (source → `lib/`, shim → `t/integration/custom-plugins/`)
- `integration/conf/` (→ `t/integration/conf/`)
- `integration/tests/` (→ `t/integration/tests/`)
- `integration/openresty-conf/` (→ `t/openresty-integration/conf/`)
- `integration/openresty-tests/` (→ `t/openresty-integration/tests/`)
- `integration/generate-conf.sh` (→ `t/integration/generate-conf.sh`)
- `integration/Dockerfile.test-runner` (→ `t/integration/Dockerfile.test-runner`)

Note: `integration/certs/` and `integration/conf/apisix.yaml` are .gitignored so may not be tracked. If `git rm` warns about them, that's fine — they're generated files.

- [ ] **Step 4: Run all tests one final time**

```bash
make all
```

Expected: All three test suites pass with old directories removed.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: remove old unit/ and integration/ directories"
```
