# TLS ClientHello Limiter — Core/Adapter Split Design

**Date:** 2026-03-12
**Status:** Draft

## Goal

Split `tls-clienthello-limiter` into a platform-agnostic core library and thin integration adapters for APISIX and vanilla OpenResty. Replace `custom-metrics.lua` with native `nginx-lua-prometheus` (which supports TTL-based label expiration). Remove IP whitelisting from the core (handled at the routing layer in APISIX).

## Architecture

```
tls-clienthello-limiter/
  core.lua                 -- rate limiting logic, FFI IP extraction
  adapters/
    apisix.lua             -- APISIX plugin wrapper
    openresty.lua          -- vanilla OpenResty helper
```

## Core Module (`core.lua`)

### Factory

```lua
local limiter = require("tls-clienthello-limiter.core")
local lim = limiter.new({
    per_ip_rate       = 2,        -- req/sec (default)
    per_ip_burst      = 4,        -- (default)
    per_domain_rate   = 5,        -- req/sec (default)
    per_domain_burst  = 10,       -- (default)
    block_ttl         = 10,       -- seconds (default)
    dict_per_ip       = "tls-hello-per-ip",
    dict_per_domain   = "tls-hello-per-domain",
    dict_blocklist    = "tls-ip-blocklist",
    metrics           = nil,      -- optional metrics adapter
})
```

All fields are optional; defaults are applied for any omitted field.

### Metrics Adapter Interface

```lua
metrics = {
    inc_counter = function(name, labels) end,
}
```

- `name`: string
- `labels`: table or nil (e.g., `{reason = "blocklist"}`)

Only `inc_counter` is required. The core never calls any other metrics method.

### `check()` Method

```lua
local rejected, reason = lim:check()
```

Returns:
- `false` — request allowed
- `true, reason` — request should be rejected (`reason` is a string)

Error/edge-case behavior:
- If `extract_client_ip()` returns `nil` (no request context, unsupported address family): returns `false` (allow — fail open).
- If `limit_req:incoming()` returns an error other than `"rejected"` (e.g., shared dict full): logs via `ngx.log(ngx.ERR, ...)` and returns `false` (allow — fail open).
- The return type is always `boolean, string?` — never `nil`.

**Phase context:** `check()` is only valid in `ssl_client_hello_by_lua*` context. Calling from other phases will return `false` (no request → `extract_client_ip()` returns nil → fail open).

The core **never** calls `ngx.exit()`. The caller decides how to handle rejection.

### Internal Flow

1. **FFI extract binary client IP** — `extract_client_ip()` returns `(addr_ptr, addr_len, addr_type)` or `nil`. Uses pre-allocated FFI buffers (safe: single-thread per worker).
2. **Binary key** — `ffi_str(addr_ptr, addr_len)` produces a 4-byte (IPv4) or 16-byte (IPv6) key. No text IP conversion anywhere.
3. **T0: Blocklist check** — `dict_blocklist:get(bin_key)`. If hit → return `true, "blocklist"`.
4. **Extract SNI** — `ssl_clt.get_client_hello_server_name()`. Deferred past blocklist (not needed for blocked IPs).
5. **T1: Per-IP rate limit** — `limit_req:incoming(bin_key, true)`. If rejected → auto-block (`dict_blocklist:set(bin_key, true, block_ttl)`) → return `true, "per_ip"`.
6. **T2: Per-SNI rate limit** — `limit_req:incoming(sni, true)`. Only if SNI present. If rejected → return `true, "per_domain"`.
7. **Return `false`** — all checks passed.

Metrics are emitted at each decision point (see Metrics section).

### FFI Details

Reused from current implementation:
- `ngx_http_lua_ffi_ssl_raw_client_addr` for raw sockaddr access
- `sockaddr_in` / `sockaddr_in6` structs for binary IP extraction
- `pcall(ffi.cdef, ...)` to guard against redefinition
- Pre-allocated output buffers: `addr_pp`, `sizep`, `typep`, `errmsgp`

### Dependencies

| Dependency | Purpose |
|---|---|
| `resty.limit.req` | Leaky bucket rate limiting |
| `ngx.ssl.clienthello` | SNI extraction from ClientHello |
| `ffi` | Binary IP extraction |
| `resty.core.base` | `get_request()` for FFI calls |

No APISIX dependencies. No ipmatcher. No text IP formatting.

### Logging

Core uses `ngx.log(ngx.ERR, ...)` directly for error conditions (e.g., unexpected `limit_req` errors). This is available in both APISIX and vanilla OpenResty contexts. No logging adapter is needed.

### Performance: Pre-allocated Label Tables

Label tables passed to `metrics.inc_counter()` are pre-allocated as module-level constants (e.g., `local LABELS_BLOCKLIST = {reason = "blocklist"}`). The metrics adapter **must not mutate** the labels table. This avoids per-request table allocation in the hot path.

## APISIX Adapter (`adapters/apisix.lua`)

Standard APISIX plugin module (`_M` table with `name`, `version`, `priority`, `schema`).

### APISIX Global Reference

The monkey-patch targets `_G.apisix.ssl_client_hello_phase`. APISIX sets `_G.apisix` during bootstrap (in `apisix/init.lua` the module table is returned and assigned to the global by the entry point). The adapter checks `if apisix and apisix.ssl_client_hello_phase` before patching, and logs an error if not found (same guard as the current plugin). This is version-specific to APISIX's bootstrap behavior.

### Lifecycle

**`init()`:**
1. Read config from `plugin.plugin_attr("tls-clienthello-limiter")`
2. Build metrics adapter bridging to APISIX's prometheus exporter (or `nil` if unavailable)
3. Create limiter: `core.new(merged_opts)`
4. Monkey-patch `_G.apisix.ssl_client_hello_phase`:
   ```lua
   local original = apisix.ssl_client_hello_phase
   apisix.ssl_client_hello_phase = function()
       local rejected = lim:check()
       if rejected then
           return ngx_exit(ngx.ERROR)
       end
       return original()
   end
   ```
5. Log effective configuration at `warn` level (rates, burst, block_ttl).

**`init_worker()`:**
- Not needed. The custom-metrics sweeper is removed, and APISIX's prometheus exporter manages its own lifecycle.

**`destroy()`:**
- Restore original `apisix.ssl_client_hello_phase`

**`check_schema()`:**
- Validates against empty schema (no per-route config)

### Dependencies

| Dependency | Purpose |
|---|---|
| `tls-clienthello-limiter.core` | Core logic |
| `apisix.core` | Logging, schema validation |
| `apisix.plugin` | `plugin_attr()` config access |

## OpenResty Adapter (`adapters/openresty.lua`)

Helper module for vanilla OpenResty (no APISIX).

### API

```lua
local adapter = require("tls-clienthello-limiter.adapters.openresty")

-- Call once in init_worker_by_lua_block
adapter.init({
    per_ip_rate = 2,
    -- ... config overrides
    -- prometheus metrics created with exptime for TTL
})

-- Call in ssl_client_hello_by_lua_block
adapter.check()
-- Calls ngx_exit(ngx.ERROR) on rejection; returns normally if allowed
```

### Responsibilities

1. **`init(opts)`** — Create `nginx-lua-prometheus` counter objects with `exptime` parameter for TTL-based expiration. Build metrics adapter table. Call `core.new(opts)`.
2. **`check()`** — Call `lim:check()`. If rejected, call `ngx_exit(ngx.ERROR)`.

### nginx.conf Integration

```nginx
lua_shared_dict tls-hello-per-ip 10m;
lua_shared_dict tls-hello-per-domain 10m;
lua_shared_dict tls-ip-blocklist 5m;
lua_shared_dict prometheus-metrics 10m;

init_worker_by_lua_block {
    local adapter = require("tls-clienthello-limiter.adapters.openresty")
    adapter.init()
}

server {
    ssl_client_hello_by_lua_block {
        local adapter = require("tls-clienthello-limiter.adapters.openresty")
        adapter.check()
    }
}
```

### Dependencies

| Dependency | Purpose |
|---|---|
| `tls-clienthello-limiter.core` | Core logic |
| `nginx-lua-prometheus` | Native prometheus with TTL support |

## Metrics

All metrics are fixed-cardinality counters emitted via the injected adapter.

| Metric | Labels | Emitted when |
|---|---|---|
| `tls_clienthello_blocked_total` | `{reason="blocklist"}` | Blocklist hit |
| `tls_clienthello_rejected_total` | `{layer="per_ip"}` | Per-IP rate exceeded |
| `tls_clienthello_rejected_total` | `{layer="per_domain"}` | Per-SNI rate exceeded |
| `tls_ip_autoblock_total` | — | IP added to blocklist |
| `tls_clienthello_passed_total` | `{layer="per_ip"}` | Per-IP rate OK |
| `tls_clienthello_passed_total` | `{layer="per_domain"}` | Per-domain rate OK |
| `tls_clienthello_no_sni_total` | — | No SNI in ClientHello |

## Removed

- **`custom-metrics.lua`** — replaced by native `nginx-lua-prometheus` with TTL expiration
- **IP whitelisting** — no longer in core; handled at APISIX routing layer
- **`tls_clienthello_total` metric** — removed (was high-cardinality with `{domain=<sni>}`)
- **Text IP conversion** — eliminated; all IP operations use binary keys

## Migration Notes

- **Rate limiter key format change:** Per-IP keys switch from text IP strings to binary (4/16 bytes). Since `resty.limit.req` stores state in shared dicts keyed by this value, a deploy will effectively reset all rate-limit counters. This is acceptable — counters recover within seconds of the configured rate window.

## Shared Dicts Required

| Dict name | Purpose | Both adapters |
|---|---|---|
| `tls-hello-per-ip` | Per-IP rate limiter state | Yes |
| `tls-hello-per-domain` | Per-SNI rate limiter state | Yes |
| `tls-ip-blocklist` | Auto-blocked IPs (binary keys, TTL) | Yes |
| `prometheus-metrics` | Prometheus metric storage | OpenResty adapter only |

## Test Impact

- Integration tests (`test_tls_rate_limit.py`, `test_custom_metrics.py`) need updating for new module paths
- `test_custom_metrics.py` may be removed or repurposed for native prometheus
- Unit tests can now test `core.lua` in isolation by mocking shared dicts and metrics adapter
