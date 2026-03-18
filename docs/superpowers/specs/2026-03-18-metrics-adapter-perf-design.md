# Metrics Adapter Performance Fix

**Date:** 2026-03-18
**Scope:** `openresty.lua` and `apisix.lua` metrics adapters

## Problem

Both `openresty.lua` and `apisix.lua` `inc_counter` implementations perform redundant
work on every request:

- Allocate a new `label_names` table
- Iterate with `pairs()`
- Call `table.sort()`
- Allocate a new `vals` table
- Iterate again to build sorted values

The labels passed from `init.lua` are pre-allocated module-level constants
(`LABELS_BLOCKLIST`, `LABELS_LAYER_IP`, `LABELS_LAYER_DOMAIN`), so the same
table reference with the same content arrives every time. All this per-call
work is redundant.

Additionally, the APISIX adapter calls `prometheus_mod.get_prometheus()` on
every `inc_counter` invocation — an unnecessary function call per request.

## Call Sites (from init.lua)

All label arguments are module-level constant tables defined in `init.lua`.
The caching strategy depends on **table identity** — the same table reference
is passed on every call.

```
-- LABELS_BLOCKLIST = {reason = "blocklist"}
metrics.inc_counter("tls_clienthello_blocked_total",  LABELS_BLOCKLIST)

-- LABELS_LAYER_IP = {layer = "per_ip"}
metrics.inc_counter("tls_clienthello_rejected_total", LABELS_LAYER_IP)
metrics.inc_counter("tls_ip_autoblock_total")          -- nil labels
metrics.inc_counter("tls_clienthello_passed_total",   LABELS_LAYER_IP)

-- LABELS_LAYER_DOMAIN = {layer = "per_domain"}
metrics.inc_counter("tls_clienthello_rejected_total", LABELS_LAYER_DOMAIN)
metrics.inc_counter("tls_clienthello_passed_total",   LABELS_LAYER_DOMAIN)
metrics.inc_counter("tls_clienthello_no_sni_total")    -- nil labels
```

Key observation: some counter names appear with different label values
(e.g. `tls_clienthello_rejected_total` with `per_ip` and `per_domain`).
Counter name alone is not a unique key — but `(name, labels_table_ref)` is,
because labels are reused constants.

## Invariants

The caching strategy depends on two invariants. Both hold today and must be
preserved by future changes:

1. **Labels are module-level constants.** The same table reference is passed
   on every call. If labels were created per-request, `val_cache` and
   `order_cache` would grow without bound. A code comment must warn future
   maintainers.

2. **Each counter name is always called with the same label schema.** For
   example, `tls_clienthello_rejected_total` is always called with a
   `{layer = ...}` table. The counter is registered with sorted label key
   names on first call; subsequent calls with the same name but different
   key structure would produce incorrect values. This invariant holds today
   because all call sites in `init.lua` are static.

## Solution

Cache counter objects by name and label value arrays by labels table identity.

### Helper definitions

```lua
--- Extract keys from a table, sort alphabetically, return as array.
--- Returns a new table. Called at most once per unique labels table ref.
local function build_sorted_keys(labels)
    local keys = {}
    for k in pairs(labels) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
end

--- Build an array of label values in the order specified by sorted keys.
--- Returns a new table. Called at most once per unique labels table ref.
local function build_vals(labels, sorted_keys)
    local vals = {}
    for i = 1, #sorted_keys do
        vals[i] = labels[sorted_keys[i]]
    end
    return vals
end
```

### Data structures (built lazily, once per unique call)

```lua
local counters = {}    -- name -> prometheus counter object
local val_cache = {}   -- labels_table_ref -> {sorted_vals_array}
local order_cache = {} -- labels_table_ref -> {sorted_key_names}
```

### Hot-path inc_counter (OpenResty)

```lua
inc_counter = function(name, labels)
    if not counters[name] then
        -- cold path: register counter (once per unique name)
        local label_names
        if labels then
            label_names = build_sorted_keys(labels)
            order_cache[labels] = label_names
        end
        counters[name] = prometheus:counter(name, name, label_names or {}, exptime)
    end
    if labels then
        local vals = val_cache[labels]
        if not vals then
            -- cold path: first time seeing this labels table ref.
            -- order_cache may already be populated from counter registration
            -- above, OR this may be a labels ref first seen after its counter
            -- name was already registered via a different labels ref.
            -- Either way, build_sorted_keys is called at most once per ref.
            local keys = order_cache[labels] or build_sorted_keys(labels)
            order_cache[labels] = keys
            vals = build_vals(labels, keys)
            val_cache[labels] = vals
        end
        counters[name]:inc(1, vals)
    else
        counters[name]:inc(1)
    end
end
```

### Hot-path inc_counter (APISIX)

Same counter/val caching pattern, but with two differences:

1. **Lazy prometheus resolution.** In APISIX the prometheus instance may not
   be available at plugin `init()` time due to plugin loading order
   (see `exporter.lua:173` — `prometheus` is set during `http_init`).
   The fix caches after the first successful `get_prometheus()` call.

2. **No `exptime` argument.** APISIX manages counter lifecycle differently
   from vanilla OpenResty — its `counter()` calls omit the TTL parameter.
   This matches the current behavior.

**Known limitation:** If APISIX calls `exporter.destroy()`, the cached
prometheus reference becomes stale. This is acceptable because `destroy()`
is only called during plugin teardown, at which point the adapter should
not be receiving new calls.

Full pseudocode:

```lua
local cached_prometheus = nil
local counters = {}
local val_cache = {}
local order_cache = {}

inc_counter = function(name, labels)
    if not cached_prometheus then
        cached_prometheus = prometheus_mod.get_prometheus()
        if not cached_prometheus then return end
    end

    if not counters[name] then
        local label_names
        if labels then
            label_names = build_sorted_keys(labels)
            order_cache[labels] = label_names
        end
        counters[name] = cached_prometheus:counter(name, name, label_names or {})
    end

    if labels then
        local vals = val_cache[labels]
        if not vals then
            local keys = order_cache[labels] or build_sorted_keys(labels)
            order_cache[labels] = keys
            vals = build_vals(labels, keys)
            val_cache[labels] = vals
        end
        counters[name]:inc(1, vals)
    else
        counters[name]:inc(1)
    end
end
```

### Why table identity works

The label tables in `init.lua` are module-level constants:

```lua
local LABELS_BLOCKLIST    = {reason = "blocklist"}
local LABELS_LAYER_IP     = {layer = "per_ip"}
local LABELS_LAYER_DOMAIN = {layer = "per_domain"}
```

Every call to `inc_counter` passes one of these three references (or nil).
Using the table reference as a hash key in `val_cache` gives O(1) lookup
with zero string allocation.

## Performance impact

| Metric | Before (per request) | After (per request) |
|--------|---------------------|---------------------|
| Table allocations | 2 (label_names + vals) | 0 |
| `table.sort()` calls | 1 | 0 |
| `pairs()` iterations | 2 | 0 |
| `get_prometheus()` calls (APISIX) | 1 | 0 (after first) |
| Hot path | alloc + sort + iterate + inc | lookup + inc |

## Files affected

| File | Change |
|------|--------|
| `lib/resty/clienthello/ratelimit/openresty.lua` | Rewrite `build_metrics_adapter` with caching |
| `lib/resty/clienthello/ratelimit/apisix.lua` | Same pattern + lazy-cached prometheus instance |

## What stays the same

- `init.lua` — zero changes
- `config.lua` — zero changes
- `inc_counter(name, labels)` contract — unchanged signature and semantics
- All existing tests pass without modification

## Test plan

New tests to validate caching behavior:

1. **Counter registration is idempotent** — call `inc_counter` with the same
   name+labels multiple times; verify `prometheus:counter()` was called only
   once for that name (spy on the mock).

2. **Same vals array for same labels ref** — call `inc_counter` with the same
   labels table ref multiple times; capture the vals argument passed to
   `counter:inc()` on each call and assert `rawequal(vals1, vals2)` (reference
   equality, not deep equality) to confirm zero allocations after the first call.

3. **Non-constant labels degrade gracefully** — call `inc_counter` with a
   freshly-created labels table; verify it still works (counter registered,
   correct values passed).

4. **APISIX lazy prometheus resolution** — call `inc_counter` when
   `get_prometheus()` returns nil; verify no error and no crash. Then arrange
   for it to return a prometheus instance; verify subsequent calls work and
   `get_prometheus()` is not called again (spy call count == 1).
