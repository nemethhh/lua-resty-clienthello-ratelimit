# Metrics Adapter Performance Fix Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate per-request table allocations, sorting, and iteration in both metrics adapters by caching counter objects and label value arrays; fix APISIX missing `exptime` bug.

**Architecture:** Extract shared caching logic into a new `metrics.lua` module that both adapters use. OpenResty adapter passes the resolved prometheus instance directly. APISIX adapter wraps with lazy `get_prometheus()` resolution and passes `metrics_exptime` from `plugin_attr`.

**Tech Stack:** Lua/LuaJIT, busted (unit tests), Docker (test runner)

**Spec:** `docs/superpowers/specs/2026-03-18-metrics-adapter-perf-design.md`

---

## File Structure

### New Files
| File | Responsibility |
|------|---------------|
| `lib/resty/clienthello/ratelimit/metrics.lua` | Shared cached `inc_counter` builder: `build_sorted_keys`, `build_vals`, `make_cached_inc_counter(prometheus, exptime)` |
| `t/unit/spec/metrics_adapter_spec.lua` | Unit tests for the caching behavior (counter idempotency, val reference equality, graceful degradation, APISIX lazy resolution, exptime) |

### Modified Files
| File | Changes |
|------|---------|
| `lib/resty/clienthello/ratelimit/openresty.lua` | Replace `build_metrics_adapter` body with call to `metrics.make_cached_inc_counter` |
| `lib/resty/clienthello/ratelimit/apisix.lua` | Replace `build_metrics_adapter` body with lazy-prometheus wrapper over `metrics.make_cached_inc_counter`; add `metrics_exptime` from `plugin_attr`; change `build_metrics_adapter` signature to accept `exptime` |
| `lua-resty-clienthello-ratelimit-0.2.0-1.rockspec` | Add `resty.clienthello.ratelimit.metrics` module entry |

---

## Task 1: Create shared metrics module with tests

**Files:**
- Create: `lib/resty/clienthello/ratelimit/metrics.lua`
- Create: `t/unit/spec/metrics_adapter_spec.lua`

- [ ] **Step 1: Write failing test — counter registration is idempotent**

In `t/unit/spec/metrics_adapter_spec.lua`:

```lua
local helpers = require("spec.helpers")

-- Minimal prometheus mock: tracks counter() and inc() calls
local function make_prometheus_mock()
    local counter_calls = {}
    local inc_calls = {}

    local counter_obj = {
        inc = function(_, val, labels_vals)
            inc_calls[#inc_calls + 1] = { val = val, labels_vals = labels_vals }
        end,
        get_inc_calls = function()
            return inc_calls
        end,
    }

    local mock = {
        counter = function(_, name, desc, label_names, exptime)
            counter_calls[#counter_calls + 1] = {
                name = name,
                desc = desc,
                label_names = label_names,
                exptime = exptime,
            }
            return counter_obj
        end,
        get_counter_calls = function()
            return counter_calls
        end,
        get_counter_obj = function()
            return counter_obj
        end,
    }

    return mock
end

describe("metrics.make_cached_inc_counter", function()
    local metrics

    before_each(function()
        helpers.setup({})
        package.loaded["resty.clienthello.ratelimit.metrics"] = nil
        metrics = require("resty.clienthello.ratelimit.metrics")
    end)

    it("registers each counter name only once", function()
        local p = make_prometheus_mock()
        local inc = metrics.make_cached_inc_counter(p, 300)
        local labels_a = {layer = "per_ip"}

        inc("my_counter", labels_a)
        inc("my_counter", labels_a)
        inc("my_counter", labels_a)

        assert.are.equal(1, #p.get_counter_calls())
    end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose -f docker-compose.unit.yml up --build --abort-on-container-exit --exit-code-from unit-tests`

Expected: FAIL — module `resty.clienthello.ratelimit.metrics` not found.

- [ ] **Step 3: Add metrics module to rockspec**

In `lua-resty-clienthello-ratelimit-0.2.0-1.rockspec`, add the new module to `build.modules`:

```lua
        ["resty.clienthello.ratelimit.metrics"]   = "lib/resty/clienthello/ratelimit/metrics.lua",
```

(Add after the `resty.clienthello.ratelimit.apisix` line.)

Without this, `luarocks make` (run in the unit test Docker image) will not install the module and all `require("resty.clienthello.ratelimit.metrics")` calls will fail.

- [ ] **Step 4: Write minimal metrics.lua to make test pass**

In `lib/resty/clienthello/ratelimit/metrics.lua`:

```lua
-- =============================================================================
-- resty.clienthello.ratelimit.metrics — Cached metrics inc_counter builder
--
-- Caches prometheus counter objects by name and label value arrays by
-- labels table identity. Hot path: two table lookups + counter:inc().
--
-- INVARIANT: labels tables passed to inc_counter must be module-level
-- constants (same table ref on every call). Per-request label tables
-- will cause unbounded cache growth.
-- =============================================================================

local _M = {}

local table_sort = table.sort
local pairs = pairs

--- Extract keys from a table, sort alphabetically, return as array.
--- Called at most once per unique labels table ref.
local function build_sorted_keys(labels)
    local keys = {}
    for k in pairs(labels) do
        keys[#keys + 1] = k
    end
    table_sort(keys)
    return keys
end

--- Build an array of label values in the order specified by sorted keys.
--- Called at most once per unique labels table ref.
local function build_vals(labels, sorted_keys)
    local vals = {}
    for i = 1, #sorted_keys do
        vals[i] = labels[sorted_keys[i]]
    end
    return vals
end

--- Build a cached inc_counter function for a resolved prometheus instance.
--- @param prometheus table  Resolved prometheus instance (must not be nil)
--- @param exptime number|nil  TTL for counter metrics (nil = no expiry)
--- @return function inc_counter(name, labels)
function _M.make_cached_inc_counter(prometheus, exptime)
    local counters    = {}  -- name -> prometheus counter object
    local val_cache   = {}  -- labels_table_ref -> {sorted_vals_array}
    local order_cache = {}  -- labels_table_ref -> {sorted_key_names}

    return function(name, labels)
        if not counters[name] then
            -- Cold path: register counter (once per unique name)
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
                -- Cold path: first time seeing this labels table ref.
                -- order_cache may already be populated from counter registration
                -- above, OR this may be a labels ref first seen after its counter
                -- name was already registered via a different labels ref.
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
end

return _M
```

- [ ] **Step 5: Run test to verify it passes**

Run: `docker compose -f docker-compose.unit.yml up --build --abort-on-container-exit --exit-code-from unit-tests`

Expected: PASS

- [ ] **Step 6: Write remaining tests**

Add to `t/unit/spec/metrics_adapter_spec.lua` (inside the same `describe` block):

```lua
    it("reuses the same vals array for the same labels table ref", function()
        local p = make_prometheus_mock()
        local inc = metrics.make_cached_inc_counter(p, nil)
        local labels = {layer = "per_ip"}

        inc("counter_a", labels)
        inc("counter_a", labels)

        local calls = p.get_counter_obj().get_inc_calls()
        assert.are.equal(2, #calls)
        -- Reference equality: same table object, zero allocations after first call
        assert.is_true(rawequal(calls[1].labels_vals, calls[2].labels_vals))
    end)

    it("handles nil labels (no-label counters)", function()
        local p = make_prometheus_mock()
        local inc = metrics.make_cached_inc_counter(p, nil)

        inc("simple_counter")
        inc("simple_counter")

        assert.are.equal(1, #p.get_counter_calls())
        local calls = p.get_counter_obj().get_inc_calls()
        assert.are.equal(2, #calls)
        assert.is_nil(calls[1].labels_vals)
    end)

    it("works with non-constant labels (graceful degradation)", function()
        local p = make_prometheus_mock()
        local inc = metrics.make_cached_inc_counter(p, nil)

        inc("my_counter", {layer = "per_ip"})
        -- Second call with a NEW table (different ref, same content)
        inc("my_counter", {layer = "per_domain"})

        local calls = p.get_counter_obj().get_inc_calls()
        assert.are.equal(2, #calls)
        assert.are.same({"per_ip"}, calls[1].labels_vals)
        assert.are.same({"per_domain"}, calls[2].labels_vals)
    end)

    it("passes exptime to prometheus:counter()", function()
        local p = make_prometheus_mock()
        local inc = metrics.make_cached_inc_counter(p, 300)

        inc("expiring_counter", {reason = "blocklist"})

        local cc = p.get_counter_calls()
        assert.are.equal(300, cc[1].exptime)
    end)

    it("passes nil exptime when not configured", function()
        local p = make_prometheus_mock()
        local inc = metrics.make_cached_inc_counter(p, nil)

        inc("no_expiry_counter", {reason = "blocklist"})

        local cc = p.get_counter_calls()
        assert.is_nil(cc[1].exptime)
    end)

    it("sorts label keys alphabetically", function()
        local p = make_prometheus_mock()
        local inc = metrics.make_cached_inc_counter(p, nil)

        inc("multi_label", {z_key = "z_val", a_key = "a_val"})

        local cc = p.get_counter_calls()
        assert.are.same({"a_key", "z_key"}, cc[1].label_names)
        local ic = p.get_counter_obj().get_inc_calls()
        assert.are.same({"a_val", "z_val"}, ic[1].labels_vals)
    end)
```

- [ ] **Step 7: Run all tests to verify they pass**

Run: `docker compose -f docker-compose.unit.yml up --build --abort-on-container-exit --exit-code-from unit-tests`

Expected: All PASS (new tests + existing `tls_limiter_core_spec` + `config_spec`)

- [ ] **Step 8: Commit**

```bash
git add lib/resty/clienthello/ratelimit/metrics.lua t/unit/spec/metrics_adapter_spec.lua lua-resty-clienthello-ratelimit-0.2.0-1.rockspec
git commit -m "feat: add cached metrics inc_counter builder with tests

Extracts counter/label caching logic into metrics.lua. Caches counter
objects by name and label value arrays by table identity. Hot path is
two table lookups + counter:inc() — zero allocations per request."
```

---

## Task 2: Rewrite OpenResty adapter to use cached metrics

**Files:**
- Modify: `lib/resty/clienthello/ratelimit/openresty.lua:32-65`

- [ ] **Step 1: Rewrite `build_metrics_adapter` in openresty.lua**

Replace the entire `build_metrics_adapter` function (lines 32–65) with:

```lua
--- Build metrics adapter from nginx-lua-prometheus counters.
local function build_metrics_adapter(prometheus, exptime)
    local metrics = require("resty.clienthello.ratelimit.metrics")
    local inc_counter = metrics.make_cached_inc_counter(prometheus, exptime)

    return {
        inc_counter = inc_counter,
    }
end
```

- [ ] **Step 2: Run all existing tests to verify nothing breaks**

Run: `docker compose -f docker-compose.unit.yml up --build --abort-on-container-exit --exit-code-from unit-tests`

Expected: All PASS (existing `tls_limiter_core_spec` unchanged, new `metrics_adapter_spec` still passes)

- [ ] **Step 3: Commit**

```bash
git add lib/resty/clienthello/ratelimit/openresty.lua
git commit -m "perf: use cached inc_counter in OpenResty metrics adapter

Replaces per-request table allocs, pairs(), table.sort() with cached
lookups via metrics.make_cached_inc_counter. Zero allocations on hot path."
```

---

## Task 3: Rewrite APISIX adapter with caching + exptime fix

**Files:**
- Modify: `lib/resty/clienthello/ratelimit/apisix.lua:42-95`

- [ ] **Step 1: Add APISIX-specific test for lazy prometheus + exptime**

Add a new `describe` block at the bottom of `t/unit/spec/metrics_adapter_spec.lua`:

```lua
describe("APISIX adapter: lazy prometheus + exptime", function()
    -- These test the APISIX-specific wrapper pattern, not the shared module.
    -- We simulate the APISIX adapter's lazy resolution inline.
    local metrics

    before_each(function()
        helpers.setup({})
        package.loaded["resty.clienthello.ratelimit.metrics"] = nil
        metrics = require("resty.clienthello.ratelimit.metrics")
    end)

    it("silently no-ops when prometheus is unavailable", function()
        -- Simulate APISIX adapter: get_prometheus returns nil
        local get_prometheus = function() return nil end
        local cached_prometheus = nil
        local inner_inc = nil

        local inc_counter = function(name, labels)
            if not inner_inc then
                cached_prometheus = get_prometheus()
                if not cached_prometheus then return end
                inner_inc = metrics.make_cached_inc_counter(cached_prometheus, nil)
            end
            inner_inc(name, labels)
        end

        -- Should not error
        assert.has_no.errors(function()
            inc_counter("test_counter", {layer = "per_ip"})
        end)
    end)

    it("caches prometheus after first successful resolution", function()
        local p = make_prometheus_mock()
        local call_count = 0
        local get_prometheus = function()
            call_count = call_count + 1
            return p
        end

        -- Simulate APISIX adapter lazy wrapper
        local cached_prometheus = nil
        local inner_inc = nil

        local inc_counter = function(name, labels)
            if not inner_inc then
                cached_prometheus = get_prometheus()
                if not cached_prometheus then return end
                inner_inc = metrics.make_cached_inc_counter(cached_prometheus, nil)
            end
            inner_inc(name, labels)
        end

        inc_counter("c1", {layer = "per_ip"})
        inc_counter("c1", {layer = "per_ip"})
        inc_counter("c1", {layer = "per_ip"})

        assert.are.equal(1, call_count)
    end)

    it("retries get_prometheus after nil, then caches on success", function()
        local p = make_prometheus_mock()
        local call_count = 0
        local return_nil = true
        local get_prometheus = function()
            call_count = call_count + 1
            if return_nil then return nil end
            return p
        end

        -- Simulate APISIX adapter lazy wrapper
        local cached_prometheus = nil
        local inner_inc = nil

        local inc_counter = function(name, labels)
            if not inner_inc then
                cached_prometheus = get_prometheus()
                if not cached_prometheus then return end
                inner_inc = metrics.make_cached_inc_counter(cached_prometheus, nil)
            end
            inner_inc(name, labels)
        end

        -- First call: prometheus unavailable, no-op
        inc_counter("c1", {layer = "per_ip"})
        assert.are.equal(1, call_count)
        assert.are.equal(0, #p.get_counter_calls())

        -- Now prometheus becomes available
        return_nil = false
        inc_counter("c1", {layer = "per_ip"})
        assert.are.equal(2, call_count)
        assert.are.equal(1, #p.get_counter_calls())

        -- Third call: should NOT call get_prometheus again (cached)
        inc_counter("c1", {layer = "per_ip"})
        assert.are.equal(2, call_count)
    end)

    it("passes exptime from plugin_attr to counter registration", function()
        local p = make_prometheus_mock()
        local cached_prometheus = nil
        local inner_inc = nil
        local exptime = 300

        local inc_counter = function(name, labels)
            if not inner_inc then
                cached_prometheus = p
                inner_inc = metrics.make_cached_inc_counter(cached_prometheus, exptime)
            end
            inner_inc(name, labels)
        end

        inc_counter("tls_counter", {reason = "blocklist"})

        local cc = p.get_counter_calls()
        assert.are.equal(300, cc[1].exptime)
    end)
end)
```

- [ ] **Step 2: Run test to verify it passes**

Run: `docker compose -f docker-compose.unit.yml up --build --abort-on-container-exit --exit-code-from unit-tests`

Expected: PASS (tests exercise the pattern, not the actual APISIX module)

- [ ] **Step 3: Rewrite `build_metrics_adapter` in apisix.lua**

Replace `build_metrics_adapter` function (lines 42–82) with:

```lua
--- Build a metrics adapter that bridges to APISIX's prometheus.
--- @param exptime number|nil  TTL for counter metrics from plugin_attr
local function build_metrics_adapter(exptime)
    local ok, prometheus_mod = pcall(require, "apisix.plugins.prometheus.exporter")
    if not ok or not prometheus_mod then
        return nil
    end

    local metrics = require("resty.clienthello.ratelimit.metrics")
    local cached_prometheus = nil
    local inner_inc = nil

    return {
        inc_counter = function(name, labels)
            if not inner_inc then
                cached_prometheus = prometheus_mod.get_prometheus()
                if not cached_prometheus then return end
                inner_inc = metrics.make_cached_inc_counter(cached_prometheus, exptime)
            end
            inner_inc(name, labels)
        end,
    }
end
```

- [ ] **Step 4: Update `_M.init()` to read and pass `metrics_exptime`**

Replace lines 85–95 in `apisix.lua`:

```lua
function _M.init()
    -- Read plugin_attr configuration
    local attr = plugin.plugin_attr(plugin_name)
    local core_opts = {}
    local metrics_exptime
    if attr then
        core_opts.per_ip = attr.per_ip
        core_opts.per_domain = attr.per_domain
        metrics_exptime = attr.metrics_exptime
    end

    -- Build metrics adapter
    local metrics_adapter = build_metrics_adapter(metrics_exptime)
```

(The rest of `_M.init()` from line 98 onward stays exactly the same.)

- [ ] **Step 5: Run all tests**

Run: `docker compose -f docker-compose.unit.yml up --build --abort-on-container-exit --exit-code-from unit-tests`

Expected: All PASS

- [ ] **Step 6: Commit**

```bash
git add lib/resty/clienthello/ratelimit/apisix.lua t/unit/spec/metrics_adapter_spec.lua
git commit -m "perf: use cached inc_counter in APISIX adapter + fix missing exptime

APISIX adapter now uses cached metrics via metrics.make_cached_inc_counter.
Adds lazy prometheus resolution (cached after first successful call).
Fixes bug: passes metrics_exptime from plugin_attr to counter registration,
matching APISIX's built-in counter expiration pattern."
```

---

## Task 4: Final verification

- [ ] **Step 1: Run full unit test suite**

Run: `docker compose -f docker-compose.unit.yml up --build --abort-on-container-exit --exit-code-from unit-tests`

Expected: All tests pass (existing core + config specs unchanged, new metrics adapter spec passes).

- [ ] **Step 2: Run JIT trace benchmark to verify no JIT regressions**

Run: `make bench-jit`

Expected: All paths COMPILED (or COMPILED* for structural aborts). No new aborts.

- [ ] **Step 3: Verify no files changed that shouldn't have**

Before starting Task 1, note the current commit SHA (`git rev-parse HEAD`).
After all commits, run `git diff --stat <base-sha>` to confirm only these files were touched:
- `lib/resty/clienthello/ratelimit/metrics.lua` (new)
- `lib/resty/clienthello/ratelimit/openresty.lua` (modified)
- `lib/resty/clienthello/ratelimit/apisix.lua` (modified)
- `lua-resty-clienthello-ratelimit-0.2.0-1.rockspec` (modified)
- `t/unit/spec/metrics_adapter_spec.lua` (new)
