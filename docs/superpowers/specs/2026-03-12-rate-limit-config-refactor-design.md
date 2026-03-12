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

1. `opts` must be a table (or nil/absent — treated as empty config).
2. If `per_ip` is present:
   - Must be a table.
   - Required fields: `rate` (number > 0), `burst` (number >= 0), `block_ttl` (number > 0).
   - Unknown keys are an error.
3. If `per_domain` is present:
   - Must be a table.
   - Required fields: `rate` (number > 0), `burst` (number >= 0).
   - Unknown keys are an error.
4. Unknown top-level keys are an error.
5. If neither tier is configured: return success but log a warning.

On success: returns normalized config with `per_ip` and `per_domain` set to validated tables or `nil`.
On failure: returns `nil, "descriptive error message"`.

## Core Limiter Changes (`init.lua`)

### `_M.new(opts)`

- Calls `config.validate(opts)` first. Returns `nil, err` on failure.
- No hardcoded defaults — uses validated config directly.
- If `per_ip` is nil: skips `limit_req` object creation for per-IP, skips acquiring `tls-hello-per-ip` and `tls-ip-blocklist` shared dicts.
- If `per_domain` is nil: skips `limit_req` object creation for per-domain, skips acquiring `tls-hello-per-domain` shared dict.
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
- Passes nested config straight through to `_M.new(opts)`.
- Adapter-specific keys (e.g., `prometheus_dict`) stay at the top level.

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
- `check_schema()` updates to validate nested shape (or delegates to `config.validate`).

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
- Warning path: no tiers configured.

### Updated: `tls_limiter_core_spec.lua`

- All `_M.new()` calls use new nested config shape.
- New tests for per-IP-only and per-domain-only — verify disabled tier is truly skipped.
- Remove tests relying on default values.

### Updated: integration tests (APISIX + OpenResty)

- Update fixture configs to nested format.
- Add per-IP-only test case (per-domain doesn't trigger).
- Add per-domain-only test case (per-IP doesn't trigger).
- Existing scenarios (burst exceeded, auto-block, TTL expiry, metrics) unchanged — just config format.

### Updated: examples and docs

- `examples/nginx.conf` — new config format.
- `examples/apisix-config.yaml` — new config format.
- `examples/apisix-plugin-shim.lua` — update if it references config keys.
- `README.md` — new configuration documentation.

## File Changes

### New

- `lib/resty/clienthello/ratelimit/config.lua`

### Modified

- `lib/resty/clienthello/ratelimit/init.lua`
- `lib/resty/clienthello/ratelimit/openresty.lua`
- `lib/resty/clienthello/ratelimit/apisix.lua`
- `t/unit/spec/tls_limiter_core_spec.lua`
- `t/integration/tests/test_tls_rate_limit.py`
- `t/openresty-integration/tests/test_openresty_tls_rate_limit.py`
- `t/openresty-integration/conf/nginx.conf`
- `examples/nginx.conf`
- `examples/apisix-config.yaml`
- `examples/apisix-plugin-shim.lua`
- `README.md`

### No changes

- FFI code, metrics interface, shared dict names, module file structure.
