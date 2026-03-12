# Rate Limit Config Refactor — Design Spec

## Summary

Remove all default rate limit values from the TLS ClientHello rate limiter. Users must explicitly configure rate limits via a nested config shape. Each tier (per-IP, per-SNI domain) is independently optional — the user can enable one, both, or neither.

## Motivation

The current implementation ships hardcoded defaults (`per_ip_rate=2`, `per_ip_burst=4`, `per_domain_rate=5`, `per_domain_burst=10`, `block_ttl=10`). This is problematic because:

- Defaults may not suit production workloads and silently apply if the user forgets to configure.
- There is no way to enable only one tier — both are always active.
- Explicit configuration forces the user to make a conscious decision about their rate limits.

## Config Shape

### New nested format

```lua
{
  per_ip = {          -- optional table; if present, all 3 fields required
    rate      = 2,    -- number > 0, requests/sec
    burst     = 4,    -- number >= 0, burst allowance
    block_ttl = 10,   -- number > 0, seconds to auto-block IPs
  },
  per_domain = {      -- optional table; if present, both fields required
    rate  = 5,        -- number > 0, requests/sec
    burst = 10,       -- number >= 0, burst allowance
  },
}
```

### Tier activation rules

- If `per_ip` table is present: T0 blocklist + T1 per-IP rate limiting are active.
- If `per_domain` table is present: T2 per-SNI domain rate limiting is active.
- If neither is present: warn ("no rate limits configured"), module is a no-op.
- Disabled tiers are silently skipped — no errors, no warnings, no shared dict access.

### Blocklist behavior

The T0 blocklist is always active when per-IP is enabled. It is not independently configurable. When per-IP is disabled, the blocklist is also disabled.

## Validation Rules

A new `config.lua` module handles all validation:

```lua
local config = require("resty.clienthello.ratelimit.config")
local validated, err = config.validate(opts)
```

`config.validate` is a pure function — it does not log. It returns the validation result and the caller decides how to handle it (including logging warnings). This keeps the module testable without mocking `ngx.log`.

**Rules:**

1. `opts` must be a table (or nil/absent — treated as empty config).
2. If `per_ip` is present:
   - Must be a non-empty table.
   - Required fields: `rate` (number > 0), `burst` (number >= 0), `block_ttl` (number > 0).
   - `per_ip = {}` is an error (missing required fields).
   - Unknown keys are an error.
3. If `per_domain` is present:
   - Must be a non-empty table.
   - Required fields: `rate` (number > 0), `burst` (number >= 0).
   - `per_domain = {}` is an error (missing required fields).
   - Unknown keys are an error.
4. Unknown top-level keys are an error. The only recognized top-level keys are `per_ip` and `per_domain`. Adapter-specific keys (e.g., `prometheus_dict`) must be stripped by the adapter before calling `config.validate`.
5. All numeric values accept both integers and floats (Lua numbers).
6. If the old flat config shape is detected (e.g., `per_ip_rate` as a top-level key), return a specific error message: `"flat config keys (per_ip_rate, ...) are no longer supported; use nested per_ip = { rate = N, burst = N, block_ttl = N } format"`.

**Return value:** On success, returns a new table (not the input) with `per_ip` and `per_domain` set to validated tables or `nil`, and a second return value `warnings` — a list of warning strings (e.g., `{"no rate limit tiers configured"}`). On failure, returns `nil, "descriptive error message"`.

```lua
local cfg, err = config.validate(opts)
if not cfg then error(err) end
-- cfg.per_ip = { rate=N, burst=N, block_ttl=N } or nil
-- cfg.per_domain = { rate=N, burst=N } or nil
-- cfg.warnings = { "no rate limit tiers configured" } or {}
```

The caller (`_M.new` or adapters) is responsible for logging any warnings via `ngx.log(ngx.WARN, ...)`.

## Core Limiter Changes (`init.lua`)

### `_M.new(opts)` signature change

The signature changes to accept rate-limit config and metrics adapter separately:

```lua
function _M.new(opts, metrics)
```

- `opts` — the rate-limit config table (passed to `config.validate`). Contains only `per_ip` and `per_domain`.
- `metrics` — optional metrics adapter object (has `inc_counter` method). Passed separately, not inside `opts`.

This separation means `config.validate` only ever sees rate-limit keys — no need to strip `metrics` or other adapter concerns.

**Return value change:** `_M.new` currently always returns a limiter object. It now returns `limiter, warnings` on success or `nil, err` on failure. The `warnings` list comes from `config.validate`. Callers must check for `nil` before using the limiter.

### `_M.new(opts, metrics)` behavior

- Calls `config.validate(opts)` first. Returns `nil, err` on failure.
- No hardcoded defaults — uses validated config directly.
- If `per_ip` is nil: skips `limit_req` object creation for per-IP, skips acquiring `tls-hello-per-ip` and `tls-ip-blocklist` shared dicts.
- If `per_domain` is nil: skips `limit_req` object creation for per-domain, skips acquiring `tls-hello-per-domain` shared dict.
- Shared dict names remain hardcoded constants (`tls-hello-per-ip`, `tls-hello-per-domain`, `tls-ip-blocklist`) — custom dict names are not supported in this version.
- Stores `self.per_ip_enabled` and `self.per_domain_enabled` booleans.

### `_M:check()`

- T0 blocklist: skip if `not self.per_ip_enabled`.
- T1 per-IP: skip if `not self.per_ip_enabled`.
- T2 per-domain: skip if `not self.per_domain_enabled`.
- No changes to logic within each tier — only conditional execution.
- Fail-open behavior and metrics emission unchanged for enabled tiers.

## Adapter Changes

### OpenResty adapter (`openresty.lua`)

- Removes all default constants.
- Extracts adapter-specific keys (`prometheus_dict`) from opts, builds the metrics adapter, then passes the remaining rate-limit config to `_M.new(rate_opts, metrics)`.
- If `_M.new()` returns `nil, err`, the adapter calls `error()` to fail loudly at init time.
- Logs any warnings from the second return value via `ngx.log(ngx.WARN, ...)`.

Example:

```lua
require("resty.clienthello.ratelimit.openresty").init({
    per_ip = { rate = 2, burst = 4, block_ttl = 10 },
    per_domain = { rate = 5, burst = 10 },
    prometheus_dict = "prometheus-metrics",
})
```

### APISIX adapter (`apisix.lua`)

- Removes all default constants.
- Reads `plugin_attr` and translates into nested shape before passing to `_M.new()`.
- `check_schema()` delegates to `config.validate` for the tier config. APISIX-specific keys are validated separately by the adapter's own schema.
- If `_M.new()` returns `nil, err`, the adapter logs the error and does not install the `ssl_client_hello` monkey-patch — APISIX runs its original phase handler unmodified. The plugin is effectively disabled with a clear error in logs.

Example APISIX YAML:

```yaml
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

## Test Plan

### New: `config.lua` unit tests

- Valid configs: per-IP only, per-domain only, both tiers.
- Error cases: missing required fields, invalid types, out-of-range values, unknown keys.
- Error case: `per_ip = {}` and `per_domain = {}` (empty tier tables).
- Error case: old flat config keys detected — verify helpful migration error message.
- Warning path: no tiers configured — verify warnings list returned.
- Return shape: verify a new table is returned (not the input mutated).

### Updated: `tls_limiter_core_spec.lua`

- All `_M.new()` calls use new nested config shape.
- New tests for per-IP-only and per-domain-only — verify disabled tier is truly skipped.
- Remove tests relying on default values.

### Updated: integration tests (APISIX + OpenResty)

- Update fixture configs to nested format.
- Add per-IP-only test case (per-domain doesn't trigger).
- Add per-domain-only test case (per-IP doesn't trigger).
- Existing scenarios (burst exceeded, auto-block, TTL expiry, metrics) unchanged — just config format.

### New: adapter error-handling tests

- OpenResty: verify `init()` errors on invalid config (doesn't silently proceed).
- APISIX: verify plugin logs error and disables itself on invalid config.

### Updated: examples and docs

- `examples/nginx.conf` — new config format.
- `examples/apisix-config.yaml` — new config format.
- `examples/apisix-plugin-shim.lua` — update if it references config keys.
- `README.md` — new configuration documentation.

## Breaking Change Notice

This is a breaking change. The README must include a migration section:

- Old flat keys (`per_ip_rate`, `per_ip_burst`, `per_domain_rate`, `per_domain_burst`, `block_ttl`) are no longer accepted.
- The module detects old-style config and returns a helpful error with the new format.
- Users must update their `init()` call (OpenResty) or `plugin_attr` YAML (APISIX) to the nested format.
- Custom shared dict names (`dict_per_ip`, `dict_per_domain`, `dict_blocklist`) are removed. Dict names are now hardcoded constants. Users who customized dict names must rename their shared dicts to the standard names.

## File Changes

### New

- `lib/resty/clienthello/ratelimit/config.lua`

### Modified

- `lib/resty/clienthello/ratelimit/init.lua`
- `lib/resty/clienthello/ratelimit/openresty.lua`
- `lib/resty/clienthello/ratelimit/apisix.lua`
- `lua-resty-clienthello-ratelimit-0.1.0-1.rockspec` (add `config.lua` to module list)
- `t/unit/spec/tls_limiter_core_spec.lua`
- `t/unit/spec/core_helpers.lua` (update mock setup for new config shape)
- `t/integration/tests/test_tls_rate_limit.py`
- `t/openresty-integration/tests/test_openresty_tls_rate_limit.py`
- `t/openresty-integration/conf/nginx.conf`
- `examples/nginx.conf`
- `examples/apisix-config.yaml`
- `examples/apisix-plugin-shim.lua`
- `README.md`

### No changes

- FFI code, metrics interface, shared dict names.
