# lua-resty-clienthello-ratelimit

`lua-resty-clienthello-ratelimit` is a three-tier TLS ClientHello rate limiter for OpenResty and Apache APISIX.

It is designed to run in `ssl_client_hello_by_lua*` and reject abusive TLS handshakes before normal HTTP request processing begins. The limiter combines:

- `T0`: IP blocklist in a shared dictionary
- `T1`: per-IP leaky-bucket rate limiting
- `T2`: per-SNI-domain leaky-bucket rate limiting

The repository includes:

- a platform-agnostic core module
- an OpenResty adapter with `nginx-lua-prometheus` metrics support
- an APISIX adapter that hooks into `ssl_client_hello_phase`
- Dockerized unit, APISIX integration, and OpenResty integration test suites

## Repository layout

```text
lib/resty/clienthello/ratelimit/
  init.lua        core limiter
  config.lua      config validation
  openresty.lua   OpenResty adapter
  apisix.lua      APISIX adapter

examples/
  nginx.conf              example OpenResty config
  apisix-config.yaml      example APISIX config fragment
  apisix-plugin-shim.lua  example APISIX plugin shim

t/
  unit/                   Busted unit tests
  integration/            APISIX integration tests
  openresty-integration/  OpenResty integration tests
```

## How it works

For each TLS ClientHello:

1. The core module extracts the raw client IP address via FFI.
2. It checks whether that IP is already in the blocklist shared dict.
3. It applies a per-IP rate limit.
4. If an SNI is present, it applies a per-domain rate limit.
5. If the per-IP limiter rejects a client, the IP is automatically added to the blocklist for `block_ttl` seconds.

Configuration is required — there are no defaults. You must specify at least one rate-limiting tier:

| Tier | Key | Required fields |
| --- | --- | --- |
| Per-IP (T0+T1) | `per_ip` | `rate` (number > 0), `burst` (number >= 0), `block_ttl` (number > 0) |
| Per-domain (T2) | `per_domain` | `rate` (number > 0), `burst` (number >= 0) |

Shared dictionaries (names are fixed):

| Dict | Purpose |
| --- | --- |
| `tls-hello-per-ip` | Per-IP rate limiter state |
| `tls-hello-per-domain` | Per-SNI rate limiter state |
| `tls-ip-blocklist` | Auto-blocked IPs with TTL |

## Requirements

For local development and test execution:

- Docker with Compose support
- `make`
- `openssl` on the host, for generating the self-signed integration-test certificate

For runtime use:

- Lua 5.1 compatible environment
- OpenResty with `ssl_client_hello_by_lua*`
- `resty.limit.req`
- `ngx.ssl.clienthello`
- `resty.core`

Optional metrics integrations:

- `nginx-lua-prometheus` for the OpenResty adapter
- APISIX Prometheus plugin for the APISIX adapter

## Installation

Install from the rockspec:

```bash
luarocks make
```

This publishes the following Lua modules:

- `resty.clienthello.ratelimit`
- `resty.clienthello.ratelimit.config`
- `resty.clienthello.ratelimit.openresty`
- `resty.clienthello.ratelimit.apisix`

## Core module

The core module is platform-agnostic and exposes `new(opts, metrics)` plus `check()`.

```lua
local limiter = require("resty.clienthello.ratelimit")

local lim, warnings = limiter.new({
    per_ip = { rate = 2, burst = 4, block_ttl = 10 },
    per_domain = { rate = 5, burst = 10 },
}, my_metrics_adapter)

local rejected, reason = lim:check()
if rejected then
    -- reason is one of: "blocklist", "per_ip", "per_domain"
end
```

Notes:

- `check()` must run in `ssl_client_hello_by_lua*` context.
- If client IP extraction fails, the limiter currently returns `false` and allows the handshake to continue.
- If no SNI is present, only the blocklist and per-IP layers are applied.

The optional `metrics` adapter is expected to expose:

```lua
{
    inc_counter = function(name, labels) ... end
}
```

## OpenResty usage

An example configuration is available in [examples/nginx.conf](/home/am/Work/cdn-harden/test-harness/examples/nginx.conf).

Minimal setup:

```nginx
http {
    lua_shared_dict tls-hello-per-ip     1m;
    lua_shared_dict tls-hello-per-domain 1m;
    lua_shared_dict tls-ip-blocklist     1m;
    lua_shared_dict prometheus-metrics   1m;

    init_worker_by_lua_block {
        require("resty.clienthello.ratelimit.openresty").init({
            per_ip = { rate = 2, burst = 4, block_ttl = 10 },
            per_domain = { rate = 5, burst = 10 },
            prometheus_dict = "prometheus-metrics",
        })
    }

    server {
        listen 443 ssl;

        ssl_certificate     /path/to/server.crt;
        ssl_certificate_key /path/to/server.key;

        ssl_client_hello_by_lua_block {
            require("resty.clienthello.ratelimit.openresty").check()
        }
    }
}
```

The OpenResty adapter:

- initializes the core limiter once per worker
- optionally initializes `nginx-lua-prometheus`
- exposes `adapter.prometheus` so a `/metrics` location can call `collect()`
- rejects a handshake with `ngx.exit(ngx.ERROR)` when a limit is hit

## APISIX usage

Example files:

- [examples/apisix-config.yaml](/home/am/Work/cdn-harden/test-harness/examples/apisix-config.yaml)
- [examples/apisix-plugin-shim.lua](/home/am/Work/cdn-harden/test-harness/examples/apisix-plugin-shim.lua)

The APISIX adapter is loaded as a custom plugin shim:

```lua
local adapter = require("resty.clienthello.ratelimit.apisix")
return adapter
```

Add the shim as `apisix/plugins/tls-clienthello-limiter.lua`, then update APISIX config:

```yaml
apisix:
  extra_lua_path: "/path/to/custom-plugins/?.lua"

plugins:
  - tls-clienthello-limiter

nginx_config:
  http:
    custom_lua_shared_dict:
      tls-hello-per-ip: 1m
      tls-hello-per-domain: 1m
      tls-ip-blocklist: 1m

plugin_attr:
  tls-clienthello-limiter:
    per_ip:
      rate: 2
      burst: 4
      block_ttl: 10
    per_domain:
      rate: 5
      burst: 10
```

The APISIX adapter:

- reads settings from `plugin_attr.tls-clienthello-limiter`
- builds a metrics adapter on top of APISIX Prometheus, when available
- monkey-patches `apisix.ssl_client_hello_phase`
- restores the original phase handler in `destroy()`

## Metrics

Depending on traffic patterns and configuration, the limiter can emit:

- `tls_clienthello_blocked_total`
- `tls_clienthello_passed_total`
- `tls_clienthello_rejected_total`
- `tls_ip_autoblock_total`
- `tls_clienthello_no_sni_total`

Typical labels include:

- `reason=blocklist`
- `layer=per_ip`
- `layer=per_domain`

## Testing

The repository ships with three Docker-based test targets:

```bash
make unit
make integration
make openresty-integration
```

Or run everything:

```bash
make all
```

What each target does:

- `make unit`: builds `t/unit/Dockerfile` and runs Busted specs for the core module
- `make integration`: generates test certificates, starts APISIX plus a test runner, and executes TLS handshake plus metrics tests
- `make openresty-integration`: generates test certificates, starts OpenResty plus a test runner, and executes equivalent adapter tests

Generated artifacts:

- `t/integration/certs/server.crt`
- `t/integration/certs/server.key`
- `t/integration/conf/apisix.yaml`

Cleanup:

```bash
make clean
```

## Test endpoints

The integration harness exposes these ports on the host:

| Stack | Port | Purpose |
| --- | --- | --- |
| APISIX | `9443` | TLS test listener |
| APISIX | `9091` | Prometheus metrics |
| APISIX | `9092` | `healthz` |
| OpenResty | `19443` | TLS test listener |
| OpenResty | `19092` | metrics and `healthz` |

## License

MIT. See [LICENSE](/home/am/Work/cdn-harden/test-harness/LICENSE).
