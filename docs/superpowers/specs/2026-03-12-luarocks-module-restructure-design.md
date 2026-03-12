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
│   │   ├── certs/
│   │   ├── conf/
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
│       ├── tests/
│       │   ├── conftest.py
│       │   ├── test_openresty_healthz.py
│       │   ├── test_openresty_tls_rate_limit.py
│       │   ├── test_openresty_metrics.py
│       │   └── requirements.txt
│       └── certs/                        # Shared with t/integration/certs/
│
├── docs/
│   ├── plans/
│   └── superpowers/
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
| `integration/tests/` | `t/integration/tests/` |
| `integration/conf/` | `t/integration/conf/` |
| `integration/certs/` | `t/integration/certs/` |
| `integration/generate-conf.sh` | `t/integration/generate-conf.sh` |
| `integration/Dockerfile.test-runner` | `t/integration/Dockerfile.test-runner` |
| `integration/openresty-tests/` | `t/openresty-integration/tests/` |
| `integration/openresty-conf/Dockerfile` | `t/openresty-integration/conf/Dockerfile` |
| `integration/openresty-conf/nginx.conf` | `t/openresty-integration/conf/nginx.conf` |
| `integration/openresty-tests/Dockerfile.test-runner` | `t/openresty-integration/Dockerfile.test-runner` |
| `integration/openresty-tests/requirements.txt` | `t/openresty-integration/tests/requirements.txt` |

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
| Unit test helpers | `package.loaded["tls-clienthello-limiter.core"]` | `package.loaded["resty.clienthello.ratelimit"]` |
| nginx.conf (OpenResty) | `require("tls-clienthello-limiter.adapters.openresty")` | `require("resty.clienthello.ratelimit.openresty")` |
| APISIX plugin shim | `require("tls-clienthello-limiter.adapters.apisix")` | `require("resty.clienthello.ratelimit.apisix")` |

## Docker & Test Infrastructure

### Principle

Every Dockerfile runs `luarocks make` from the rockspec to install the module. No `lua_package_path` overrides pointing at source directories. Tests consume the module exactly as a real user would.

### Unit tests (`t/unit/Dockerfile`)

```dockerfile
FROM openresty/openresty:1.21.4.3-jammy
RUN luarocks install busted
COPY . /src
WORKDIR /src
RUN luarocks make
WORKDIR /src/t/unit
CMD ["busted", "--verbose", "spec/"]
```

The `unit/lua/` directory with the copied `core.lua` is deleted. The module is installed system-wide.

### APISIX integration tests

The APISIX Docker service installs the module via `luarocks make`. The plugin shim at `t/integration/custom-plugins/apisix/plugins/tls-clienthello-limiter.lua` is a 3-liner delegating to the installed adapter:

```lua
local adapter = require("resty.clienthello.ratelimit.apisix")
return adapter
```

### OpenResty integration tests (`t/openresty-integration/conf/Dockerfile`)

```dockerfile
FROM openresty/openresty:1.21.4.3-jammy
RUN luarocks install nginx-lua-prometheus
COPY . /src
RUN cd /src && luarocks make
COPY t/openresty-integration/conf/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
```

No `lua_package_path` hacks. Module installed to standard LuaRocks path.

### Docker Compose

Build contexts change to repo root (`.`) so the full source including rockspec is available. Volume mounts for `custom-plugins/` are removed from the OpenResty service.

### Makefile

Targets stay the same: `unit`, `integration`, `openresty-integration`, `all`, `clean`. Paths updated for `t/` structure.

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
