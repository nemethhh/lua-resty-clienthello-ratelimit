# TLS ClientHello Limiter Performance Optimization

**Date:** 2026-03-09
**Approach:** Hybrid C — FFI IP extraction + cached objects, minimal FFI surface

## Goal

Optimize `tls-clienthello-limiter.lua` for performance and low resource consumption.
The hot path (blocklisted IP under attack) should involve zero text formatting and
minimal Lua allocations.

## Decisions

- **FFI for IP extraction only** — direct `ngx_http_lua_ffi_ssl_raw_client_addr` call,
  cast sockaddr to extract binary IP. No FFI for shdict or rate limiting.
- **Binary keys for blocklist** — 4 bytes (IPv4) or 16 bytes (IPv6) instead of text IP.
  Blocklist is auto-only (populated by T1 rejections), so binary keys are internal.
- **Lazy text formatting** — text IP only created after blocklist miss, for whitelist
  check and `resty.limit.req` keys.
- **Text keys for limit.req** — text IP is already computed for whitelist, reuse it.
- **Cached objects** — `limit_req` objects created once at `init()`, shared dict
  references resolved once at `init()`, metrics resolved once at `init_worker()`.

## Request Flow

### Blocked IP (attack hot path)
```
ssl_client_hello_phase()
  -> FFI: raw_client_addr -> sockaddr pointer (no Lua string)
  -> FFI: cast sockaddr_in/in6 -> binary IP pointer (4 or 16 bytes)
  -> ffi_str(ptr, len) -> binary key (single small allocation)
  -> cached_blocklist_dict:get(binary_key) -> HIT -> ngx.exit
```

### Non-blocked, non-whitelisted traffic
```
  -> binary blocklist miss
  -> format text IP from binary (lazy)
  -> ipmatcher:match(text_ip) -> whitelist check
  -> cached_lim_ip:incoming(text_ip, true) -> T1
  -> cached_lim_dom:incoming(sni, true) -> T2
  -> original_ssl_client_hello_phase()
```

## FFI IP Extraction

POSIX sockaddr structs defined via `ffi.cdef`. Pre-allocated module-level FFI buffers
(`char*[1]`, `size_t[1]`, `int[1]`) reused across requests.

```lua
local rc = C.ngx_http_lua_ffi_ssl_raw_client_addr(r, addr_pp, sizep, typep, errmsgp)
-- addr_type: 1=inet, 2=inet6
-- cast to sockaddr_in*/sockaddr_in6*, extract sin_addr/sin6_addr
```

`get_request()` from `resty.core.base` provides the request pointer.

## Cached Objects

Created in `init()` after reading `plugin_attr` config:

- `cached_blocklist_dict` — `ngx.shared["tls-ip-blocklist"]`
- `cached_lim_ip` — `limit_req.new(DICT_PER_IP, rate, burst)`
- `cached_lim_dom` — `limit_req.new(DICT_PER_DOMAIN, rate, burst)`

Metrics resolved once in `init_worker()` — no `pcall(require)` in hot path.

## Lazy Text Formatting

```lua
-- IPv4: concatenation (faster than string.format)
b[0] .. "." .. b[1] .. "." .. b[2] .. "." .. b[3]

-- IPv6: string.format for hex (rarer path, non-blocked only)
str_format("%x", b[i] * 256 + b[i + 1])
```

## Error Handling

- `get_request()` returns nil -> fall through to original phase handler
- FFI `raw_client_addr` fails -> fall through to original phase handler
- `limit_req.new()` fails at init -> tier skipped, warning logged
- No new failure modes introduced

## What Stays The Same

- `resty.limit.req` — cached at init, otherwise unchanged
- `resty.ipmatcher` — whitelist matching with text IP
- `ngx.shared` Lua API — all dict operations
- `custom-metrics` API calls
- Plugin lifecycle (`init`, `init_worker`, `destroy`, `check_schema`)
- Three-tier logic (T0/T1/T2) ordering and semantics
- SNI extraction via `ssl_clt.get_client_hello_server_name()`
- Config via `plugin_attr`

## Files Affected

Only `integration/custom-plugins/apisix/plugins/tls-clienthello-limiter.lua`.
No changes to custom-metrics, config, or tests.
