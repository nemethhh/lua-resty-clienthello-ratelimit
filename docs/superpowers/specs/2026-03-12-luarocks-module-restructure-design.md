# lua-resty-clienthello-ratelimit — LuaRocks Module Restructure

**Date:** 2026-03-12
**Status:** Approved
**Version:** 0.1.0

## Goal

Restructure the `test-harness` repository into a publishable `lua-resty-clienthello-ratelimit` LuaRocks package. The module ships a platform-agnostic TLS ClientHello rate limiter core with adapters for OpenResty and APISIX. The existing test harness becomes the module's test suite.

## Public API

| Consumer | Require path | Module |
|----------|-------------|--------|
| Advanced / custom | `require("resty.clienthello.ratelimit")` | Core three-tier rate limiter |
| OpenResty | `require("resty.clienthello.ratelimit.openresty")` | OpenResty adapter |
| APISIX | `require("resty.clienthello.ratelimit.apisix")` | APISIX adapter |

The core is a documented public API for advanced users building custom integrations (e.g., Kong). The adapters are the easy path for OpenResty and APISIX users.

APISIX requires a plugin shim at `apisix/plugins/tls-clienthello-limiter.lua` — users create this 3-line file themselves. An example is provided in `examples/`.

## Target Repository Layout

```
lua-resty-clienthello-ratelimit/
├── lua-resty-clienthello-ratelimit-0.1.0-1.rockspec
├── LICENSE
├── Makefile
├── docker-compose.unit.yml
├── docker-compose.integration.yml
├── docker-compose.openresty-integration.yml
│
├── lib/
│   └── resty/
│       └── clienthello/
│           └── ratelimit/
│               ├── init.lua              # Core (renamed from core.lua)
│               ├── openresty.lua         # OpenResty adapter
│               └── apisix.lua            # APISIX adapter
│
├── examples/
│   ├── apisix-plugin-shim.lua
│   ├── nginx.conf
│   └── apisix-config.yaml
│
├── t/
│   ├── unit/
│   │   ├── Dockerfile
│   │   └── spec/
│   │       ├── helpers.lua
│   │       ├── core_helpers.lua
│   │       └── tls_limiter_core_spec.lua
│   │
│   ├── integration/                      # APISIX integration tests
│   │   ├── Dockerfile.apisix             # Custom APISIX image (luarocks make)
│   │   ├── certs/
│   │   ├── conf/
│   │   │   ├── config.yaml
│   │   │   ├── apisix.yaml.tpl
│   │   │   └── apisix.yaml              # Generated
│   │   ├── custom-plugins/
│   │   │   └── apisix/plugins/
│   │   │       └── tls-clienthello-limiter.lua
│   │   ├── generate-conf.sh
│   │   ├── Dockerfile.test-runner
│   │   └── tests/
│   │       ├── conftest.py
│   │       ├── test_healthz.py
│   │       ├── test_tls_rate_limit.py
│   │       └── requirements.txt
│   │
│   └── openresty-integration/            # OpenResty integration tests
│       ├── conf/
│       │   ├── Dockerfile
│       │   └── nginx.conf
│       ├── Dockerfile.test-runner
│       └── tests/
│           ├── conftest.py
│           ├── test_openresty_healthz.py
│           ├── test_openresty_tls_rate_limit.py
│           ├── test_openresty_metrics.py
│           └── requirements.txt
│
├── docs/
│   ├── plans/
│   └── superpowers/
│       ├── plans/
│       └── specs/
│
└── .gitignore
```

## File Migration Map

### Moved to `lib/` (distributable source)

| Current path | New path |
|---|---|
| `integration/custom-plugins/tls-clienthello-limiter/core.lua` | `lib/resty/clienthello/ratelimit/init.lua` |
| `integration/custom-plugins/tls-clienthello-limiter/adapters/openresty.lua` | `lib/resty/clienthello/ratelimit/openresty.lua` |
| `integration/custom-plugins/tls-clienthello-limiter/adapters/apisix.lua` | `lib/resty/clienthello/ratelimit/apisix.lua` |

### Moved to `examples/`

| Current path | New path |
|---|---|
| `integration/custom-plugins/apisix/plugins/tls-clienthello-limiter.lua` | `examples/apisix-plugin-shim.lua` |

### Moved to `t/` (test infrastructure)

| Current path | New path |
|---|---|
| `unit/` | `t/unit/` |
| `integration/tests/conftest.py` | `t/integration/tests/conftest.py` |
| `integration/tests/test_healthz.py` | `t/integration/tests/test_healthz.py` |
| `integration/tests/test_tls_rate_limit.py` | `t/integration/tests/test_tls_rate_limit.py` |
| `integration/tests/requirements.txt` | `t/integration/tests/requirements.txt` |
| `integration/conf/config.yaml` | `t/integration/conf/config.yaml` |
| `integration/conf/apisix.yaml.tpl` | `t/integration/conf/apisix.yaml.tpl` |
| `integration/conf/apisix.yaml` | `t/integration/conf/apisix.yaml` |
| `integration/certs/` | `t/integration/certs/` |
| `integration/generate-conf.sh` | `t/integration/generate-conf.sh` |
| `integration/Dockerfile.test-runner` | `t/integration/Dockerfile.test-runner` |
| `integration/openresty-conf/Dockerfile` | `t/openresty-integration/conf/Dockerfile` |
| `integration/openresty-conf/nginx.conf` | `t/openresty-integration/conf/nginx.conf` |
| `integration/openresty-tests/conftest.py` | `t/openresty-integration/tests/conftest.py` |
| `integration/openresty-tests/test_openresty_healthz.py` | `t/openresty-integration/tests/test_openresty_healthz.py` |
| `integration/openresty-tests/test_openresty_tls_rate_limit.py` | `t/openresty-integration/tests/test_openresty_tls_rate_limit.py` |
| `integration/openresty-tests/test_openresty_metrics.py` | `t/openresty-integration/tests/test_openresty_metrics.py` |
| `integration/openresty-tests/requirements.txt` | `t/openresty-integration/tests/requirements.txt` |
| `integration/openresty-tests/Dockerfile.test-runner` | `t/openresty-integration/Dockerfile.test-runner` |

### New files

| Path | Purpose |
|---|---|
| `t/integration/Dockerfile.apisix` | Custom APISIX image that runs `luarocks make` to install the module |

### Deleted

| Path | Reason |
|---|---|
| `unit/lua/tls-clienthello-limiter/core.lua` | No longer needed — `luarocks make` installs the module |
| `integration/custom-plugins/` (entire tree) | Source moved to `lib/`, shim moved to `examples/` |
| `integration/openresty-conf/` | Moved to `t/openresty-integration/conf/` |
| `integration/openresty-tests/` | Moved to `t/openresty-integration/tests/` |

### Kept as-is

| Path | Notes |
|---|---|
| `docs/` | Existing design docs and specs |
| `.gitignore` | Updated for new cert/config paths |
| `reference/` | Development reference, .gitignored |

**Note:** The `<owner>` placeholder in the rockspec `source.url` and `description.homepage` must be filled in before remote `luarocks install` works. The `luarocks make` local workflow works regardless.

## Rockspec

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

No explicit dependency on `lua-resty-limit-traffic` or `nginx-lua-prometheus` — these are OpenResty built-ins or optional peer dependencies. Runtime requirements documented in README.

## Require Path Changes

All internal `require()` calls update from old to new paths:

| File | Old require | New require |
|---|---|---|
| `openresty.lua` | `require("tls-clienthello-limiter.core")` | `require("resty.clienthello.ratelimit")` |
| `apisix.lua` | `require("tls-clienthello-limiter.core")` | `require("resty.clienthello.ratelimit")` |
| Unit test spec | `require("tls-clienthello-limiter.core")` | `require("resty.clienthello.ratelimit")` |
| Unit test helpers (`helpers.lua`) | `package.loaded["tls-clienthello-limiter.core"]` | `package.loaded["resty.clienthello.ratelimit"]` |
| Unit test helpers (`helpers.lua`) | `package.loaded["custom-metrics"]` | Remove (dead reference) |
| nginx.conf (OpenResty) | `require("tls-clienthello-limiter.adapters.openresty")` | `require("resty.clienthello.ratelimit.openresty")` |
| APISIX plugin shim | `require("tls-clienthello-limiter.adapters.apisix")` | `require("resty.clienthello.ratelimit.apisix")` |

## Docker & Test Infrastructure

### Principle

Every Dockerfile runs `luarocks make` from the rockspec to install the module. No `lua_package_path` overrides pointing at source directories. Tests consume the module exactly as a real user would.

### Unit tests (`t/unit/Dockerfile`)

```dockerfile
FROM openresty/openresty:jammy
RUN luarocks install busted
COPY . /src
WORKDIR /src
RUN luarocks make
WORKDIR /src/t/unit
CMD ["busted", "--verbose", "spec/"]
```

The `unit/lua/` directory with the copied `core.lua` is deleted. The module is installed system-wide.

### APISIX integration tests

Currently APISIX uses the stock `apache/apisix:3.15.0-ubuntu` image with volume mounts for custom plugins. After restructuring, a custom Dockerfile is needed to run `luarocks make`.

**New file: `t/integration/Dockerfile.apisix`**

```dockerfile
FROM apache/apisix:3.15.0-ubuntu
COPY . /src
RUN cd /src && luarocks make
```

The module is installed system-wide. The plugin shim at `t/integration/custom-plugins/apisix/plugins/tls-clienthello-limiter.lua` is a 3-liner delegating to the installed adapter:

```lua
local adapter = require("resty.clienthello.ratelimit.apisix")
return adapter
```

**`config.yaml` change:** The `extra_lua_path` only needs to cover the plugin shim directory now (the module itself is installed via LuaRocks):

```yaml
# Before:
extra_lua_path: "/usr/local/apisix/custom-plugins/?.lua"
# After (shim still needed for APISIX plugin discovery):
extra_lua_path: "/usr/local/apisix/custom-plugins/?.lua"
```

The value stays the same — APISIX needs the shim path to discover the plugin entry point. The shim delegates to the LuaRocks-installed adapter.

### OpenResty integration tests (`t/openresty-integration/conf/Dockerfile`)

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

No `lua_package_path` hacks or `custom-plugins` volume mounts. Module installed to standard LuaRocks path. Uses unpinned `:jammy` tag to match current practice.

### Test-runner Dockerfiles

Both `t/integration/Dockerfile.test-runner` and `t/openresty-integration/Dockerfile.test-runner` need updated COPY paths since build contexts change to repo root. Example for APISIX test runner:

```dockerfile
FROM python:3.12-slim
COPY t/integration/tests/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt
WORKDIR /tests
COPY t/integration/tests/ /tests/
COPY t/integration/certs/ /certs/
CMD ["pytest", "-v", "--tb=short", "/tests/"]
```

OpenResty test runner follows the same pattern with `t/openresty-integration/tests/` paths. Certs are shared — the OpenResty test runner copies from `t/integration/certs/` (single source of generated certs).

### Docker Compose

All build contexts change to repo root (`.`) so the full source including rockspec is available.

**`docker-compose.integration.yml` key changes:**
- APISIX service: `build: { context: ., dockerfile: t/integration/Dockerfile.apisix }` (replaces stock image + volume mounts)
- APISIX service: volume mount for custom-plugins changes to `./t/integration/custom-plugins:/usr/local/apisix/custom-plugins:ro`
- APISIX service: config volume mounts change to `./t/integration/conf/...`
- Test runner: `build: { context: ., dockerfile: t/integration/Dockerfile.test-runner }`

**`docker-compose.openresty-integration.yml` key changes:**
- OpenResty service: `build: { context: ., dockerfile: t/openresty-integration/conf/Dockerfile }`
- OpenResty service: `custom-plugins` volume mount removed (module installed via `luarocks make`)
- Test runner: `build: { context: ., dockerfile: t/openresty-integration/Dockerfile.test-runner }`

**`docker-compose.unit.yml` key changes:**
- Unit test service: `build: { context: ., dockerfile: t/unit/Dockerfile }`

### Certs sharing

Both APISIX and OpenResty integration tests use the same generated certs. `generate-conf.sh` outputs to `t/integration/certs/`. The OpenResty conf Dockerfile and test-runner Dockerfile both reference `t/integration/certs/` — there is no separate `t/openresty-integration/certs/` directory.

### Makefile

Targets stay the same: `unit`, `integration`, `openresty-integration`, `all`, `clean`. Path changes:
- `certs` target: `bash t/integration/generate-conf.sh`
- `clean` target: remove `t/integration/certs/`, `t/integration/conf/apisix.yaml`

## Examples Directory

Not installed by the rockspec. Not used by tests. Provides copy-paste starting points:

- **`examples/apisix-plugin-shim.lua`** — The 3-line shim users place at `apisix/plugins/tls-clienthello-limiter.lua`
- **`examples/nginx.conf`** — Minimal working OpenResty config showing `init_worker_by_lua_block`, `ssl_client_hello_by_lua_block`, and `/metrics`
- **`examples/apisix-config.yaml`** — Minimal APISIX config showing `extra_lua_path`, `custom_lua_shared_dict`, `plugin_attr`, and plugin enablement

## Logic Changes

None. The rate limiter core, adapters, and all test assertions are unchanged. This is a purely structural refactoring.

## Compatibility

- **Minimum OpenResty version:** 1.21.4+
- **APISIX:** 3.x (tested against 3.15.0)
- **Runtime dependencies:** `resty.limit.req` (OpenResty built-in), `ngx.ssl.clienthello` (OpenResty built-in), `nginx-lua-prometheus` (optional, OpenResty adapter only)

## Scope Boundary

This design covers restructuring only. The following are explicitly out of scope and are follow-up work:

- Writing a README
- Adding CI/CD (GitHub Actions)
- Publishing to LuaRocks registry
- Adding a LICENSE file
- Changelog / release process
