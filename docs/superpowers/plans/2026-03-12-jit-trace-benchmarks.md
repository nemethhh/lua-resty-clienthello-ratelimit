# JIT Trace Analysis Benchmarks Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a JIT trace analysis tool that verifies all hot paths in the TLS ClientHello rate limiter JIT-compile cleanly under LuaJIT 2.1.

**Architecture:** Standalone `resty` script (`bench/jit_trace.lua`) uses `jit.attach(callback, "trace")` to capture trace events per code path. Minimal mocks (`bench/mocks.lua`) replace `resty.limit.req`, `ngx.ssl.clienthello`, and `ngx.shared` dicts. Runs in Docker via `make bench-jit` for consistent LuaJIT version.

**Tech Stack:** LuaJIT 2.1 (via OpenResty), `jit.attach`, `jit.vmdef`, `jit.util`, Docker, Make

**Spec:** `docs/superpowers/specs/2026-03-12-jit-trace-benchmarks-design.md`

---

## Chunk 1: Mock Layer and JIT Harness Core

### Task 1: Create bench/mocks.lua

**Files:**
- Create: `bench/mocks.lua`

- [ ] **Step 1: Create bench/mocks.lua with all mocks**

```lua
-- bench/mocks.lua — Minimal mocks for JIT trace benchmarks
--
-- Provides lightweight replacements for OpenResty modules that
-- require nginx request context. Designed for use with `resty`
-- (real LuaJIT/FFI available, but no active HTTP request).
local ffi      = require("ffi")
local ffi_new  = ffi.new
local ffi_cast = ffi.cast
local ffi_str  = ffi.string

-- Ensure sockaddr structs are defined (init.lua uses pcall for these too,
-- but we need them available before init.lua is loaded for make_ffi_extract_fn)
pcall(ffi.cdef, [[
  struct sockaddr_in {
      unsigned short  sin_family;
      unsigned short  sin_port;
      unsigned char   sin_addr[4];
      unsigned char   sin_zero[8];
  };
  struct sockaddr_in6 {
      unsigned short  sin6_family;
      unsigned short  sin6_port;
      unsigned int    sin6_flowinfo;
      unsigned char   sin6_addr[16];
      unsigned int    sin6_scope_id;
  };
]])

local _M = {}

-- ========================================================================
-- Shared Dict Mock (pure Lua table, no TTL/eviction)
-- ========================================================================
local SharedDict = {}
SharedDict.__index = SharedDict

function SharedDict.new()
    return setmetatable({ _store = {} }, SharedDict)
end

function SharedDict:get(key)
    local v = self._store[key]
    if v == nil then return nil end
    return v, 0
end

function SharedDict:set(key, value, exptime, flags)
    self._store[key] = value
    return true, nil, false
end

function SharedDict:delete(key)
    self._store[key] = nil
end

-- ========================================================================
-- resty.limit.req Mock
-- ========================================================================
-- incoming_results maps dict_name -> { delay_or_nil, err_or_nil }
local incoming_results = {}

local LimitReq = {}
LimitReq.__index = LimitReq

function LimitReq.new(dict_name, rate, burst)
    return setmetatable({ _dict_name = dict_name }, LimitReq)
end

function LimitReq:incoming(key, commit)
    local r = incoming_results[self._dict_name]
    if r then return r[1], r[2] end
    return 0  -- default: allow
end

-- ========================================================================
-- Setup Functions
-- ========================================================================

--- Install mock shared dicts into ngx.shared.
--- Must be called before requiring the rate limiter module.
function _M.setup_shared_dicts()
    ngx.shared["tls-hello-per-ip"]    = SharedDict.new()
    ngx.shared["tls-hello-per-domain"] = SharedDict.new()
    ngx.shared["tls-ip-blocklist"]    = SharedDict.new()
end

--- Install mock modules into package.loaded.
--- Must be called before requiring the rate limiter module.
function _M.setup_modules()
    package.loaded["resty.limit.req"] = LimitReq
    package.loaded["ngx.ssl.clienthello"] = {
        get_client_hello_server_name = function()
            return "bench.example.com"
        end,
    }
end

--- Configure what lim:incoming() returns per shared-dict name.
--- @param results table  e.g. { ["tls-hello-per-ip"] = { nil, "rejected" } }
function _M.set_incoming_results(results)
    incoming_results = results
end

--- Reset incoming results to default (allow all).
function _M.reset_incoming_results()
    incoming_results = {}
end

--- Get the blocklist shared dict mock for seeding.
function _M.get_blocklist_dict()
    return ngx.shared["tls-ip-blocklist"]
end

-- ========================================================================
-- extract_client_ip replacements (used with _set_extract_client_ip)
-- ========================================================================

--- Creates a function that exercises real FFI operations (ffi_cast, ffi_str)
--- on a pre-allocated sockaddr_in struct. For path 1 (JIT trace of FFI ops).
function _M.make_ffi_extract_fn()
    local sa = ffi_new("struct sockaddr_in")
    sa.sin_family = 2  -- AF_INET
    sa.sin_addr[0] = 127
    sa.sin_addr[1] = 0
    sa.sin_addr[2] = 0
    sa.sin_addr[3] = 1

    local sa_ptr = ffi_cast("char*", sa)

    return function()
        local cast_sa = ffi_cast("struct sockaddr_in*", sa_ptr)
        return ffi_str(cast_sa.sin_addr, 4)
    end
end

--- Simple binary IP return (for paths 2-6 where FFI is not the focus).
local MOCK_BIN_IP = string.char(127, 0, 0, 1)

function _M.make_simple_extract_fn()
    return function()
        return MOCK_BIN_IP
    end
end

--- Return the binary IP used by make_simple_extract_fn (for blocklist seeding).
function _M.get_mock_bin_ip()
    return MOCK_BIN_IP
end

-- ========================================================================
-- No-op metrics adapter
-- ========================================================================
function _M.make_metrics()
    return {
        inc_counter = function() end,
    }
end

--- Force-reload the rate limiter module (clears cached upvalues).
function _M.reload_limiter()
    package.loaded["resty.clienthello.ratelimit"] = nil
    package.loaded["resty.clienthello.ratelimit.config"] = nil
    return require("resty.clienthello.ratelimit")
end

return _M
```

- [ ] **Step 2: Commit**

```bash
git add bench/mocks.lua
git commit -m "bench: add mock layer for JIT trace benchmarks"
```

---

### Task 2: Create bench/jit_trace.lua with harness core

**Files:**
- Create: `bench/jit_trace.lua`

- [ ] **Step 1: Create jit_trace.lua with harness + extract_client_ip path + human output**

This is the initial skeleton: harness core, one path, human-readable output. Validates the `jit.attach` mechanism works before adding remaining paths.

```lua
#!/usr/bin/env resty
-- bench/jit_trace.lua — JIT trace analysis for lua-resty-clienthello-ratelimit
--
-- Verifies that hot paths JIT-compile cleanly under LuaJIT 2.1.
-- Uses jit.attach(callback, "trace") to capture trace events per code path.
--
-- Usage:
--   resty bench/jit_trace.lua                  # human-readable
--   resty bench/jit_trace.lua --format json    # JSON
--   resty bench/jit_trace.lua --format tap     # TAP
--
-- Exit codes:  0 = all paths compiled,  1 = trace aborts detected

local jit_util = require("jit.util")
local vmdef    = require("jit.vmdef")

-- ========================================================================
-- JIT Trace Capture Harness
-- ========================================================================

--- Format a trace abort reason from jit.attach callback args.
--- @param otr number|string  Abort reason code or string
--- @param oex any            Extra info (substituted into format string)
--- @return string
local function format_abort_reason(otr, oex)
    if type(otr) == "number" then
        local msg = vmdef.traceerr[otr] or ("unknown error %d"):format(otr)
        if oex then
            local ok, formatted = pcall(string.format, msg, oex)
            if ok then return formatted end
        end
        return msg
    end
    return tostring(otr)
end

--- Format source location from jit.util.funcinfo.
--- @param func function  The function where the event occurred
--- @param pc number      Program counter
--- @return string
local function format_location(func, pc)
    if not func then return "unknown" end
    local ok, info = pcall(jit_util.funcinfo, func, pc)
    if not ok or not info then return "unknown" end
    local source = info.source or "?"
    -- Strip leading @ from source paths
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    local line = info.currentline or info.linedefined or "?"
    return source .. ":" .. line
end

--- Run a function in a loop and capture JIT trace events.
--- @param name string       Human-readable path name
--- @param func function     The function to trace (called `iterations` times)
--- @param iterations number Number of iterations (default 200)
--- @return table            { name, status, traces, aborts }
local function check_path(name, func, iterations)
    iterations = iterations or 200

    local stops = 0
    local aborts = {}

    local function trace_cb(what, tr, tfunc, pc, otr, oex)
        if what == "stop" then
            stops = stops + 1
        elseif what == "abort" then
            aborts[#aborts + 1] = {
                reason   = format_abort_reason(otr, oex),
                location = format_location(tfunc, pc),
            }
        end
        -- "start" and "flush" events are ignored
    end

    jit.flush()
    jit.on()
    jit.attach(trace_cb, "trace")

    for _ = 1, iterations do
        func()
    end

    jit.attach(trace_cb)  -- detach (call without event type)

    local status
    if #aborts > 0 then
        status = "aborted"
    elseif stops > 0 then
        status = "compiled"
    else
        status = "no_traces"  -- too simple or JIT didn't kick in
    end
    return {
        name   = name,
        status = status,
        traces = stops,
        aborts = aborts,
    }
end

-- ========================================================================
-- Output Formatters
-- ========================================================================

local function format_human(results)
    local lines = {}
    lines[#lines + 1] = "JIT Trace Analysis — lua-resty-clienthello-ratelimit"
    lines[#lines + 1] = "====================================================="
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format(
        "  %-28s %-10s %-7s %s", "Path", "Status", "Traces", "Aborts")
    lines[#lines + 1] = string.format(
        "  %-28s %-10s %-7s %s",
        string.rep("-", 27), string.rep("-", 9), string.rep("-", 6), string.rep("-", 6))

    local compiled_count = 0
    local STATUS_LABELS = { compiled = "COMPILED", aborted = "ABORT", no_traces = "NO_TRACE" }
    for _, r in ipairs(results) do
        local status_str = STATUS_LABELS[r.status] or r.status
        lines[#lines + 1] = string.format(
            "  %-28s %-10s %-7d %d", r.name, status_str, r.traces, #r.aborts)
        if r.status == "compiled" then
            compiled_count = compiled_count + 1
        end
        for _, a in ipairs(r.aborts) do
            lines[#lines + 1] = string.format(
                "  %-28s %s at %s", "", "└─ " .. a.reason, a.location)
        end
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "====================================================="
    local total = #results
    if compiled_count == total then
        lines[#lines + 1] = string.format("Result: PASS (%d/%d paths compiled)", compiled_count, total)
    else
        lines[#lines + 1] = string.format("Result: FAIL (%d/%d paths have trace aborts)",
            total - compiled_count, total)
    end

    return table.concat(lines, "\n")
end

local function format_json(results)
    -- Minimal JSON encoder (no external dependencies)
    local compiled_count = 0
    for _, r in ipairs(results) do
        if r.status == "compiled" then compiled_count = compiled_count + 1 end
    end

    local total = #results
    local aborted_count = total - compiled_count
    local status = aborted_count == 0 and "pass" or "fail"

    local parts = {}
    parts[#parts + 1] = '{\n  "summary": {'
    parts[#parts + 1] = string.format(
        ' "total": %d, "compiled": %d, "aborted": %d, "status": "%s" },',
        total, compiled_count, aborted_count, status)
    parts[#parts + 1] = '\n  "paths": ['

    for i, r in ipairs(results) do
        local abort_strs = {}
        for _, a in ipairs(r.aborts) do
            abort_strs[#abort_strs + 1] = string.format(
                '{ "reason": "%s", "location": "%s" }',
                a.reason:gsub('"', '\\"'), a.location:gsub('"', '\\"'))
        end
        local aborts_json = table.concat(abort_strs, ", ")
        parts[#parts + 1] = string.format(
            '\n    { "name": "%s", "status": "%s", "traces": %d, "aborts": [%s] }%s',
            r.name, r.status, r.traces, aborts_json, i < total and "," or "")
    end

    parts[#parts + 1] = "\n  ]\n}"
    return table.concat(parts)
end

local function format_tap(results)
    local lines = {}
    lines[#lines + 1] = "TAP version 13"
    lines[#lines + 1] = "1.." .. #results

    for i, r in ipairs(results) do
        if r.status == "compiled" then
            lines[#lines + 1] = string.format("ok %d - %s", i, r.name)
        else
            lines[#lines + 1] = string.format("not ok %d - %s", i, r.name)
            for _, a in ipairs(r.aborts) do
                lines[#lines + 1] = "  ---"
                lines[#lines + 1] = string.format('  reason: "%s"', a.reason)
                lines[#lines + 1] = string.format('  location: "%s"', a.location)
                lines[#lines + 1] = "  ..."
            end
        end
    end

    return table.concat(lines, "\n")
end

-- ========================================================================
-- Code Path Definitions
-- ========================================================================

local mocks = require("mocks")

--- Build all 7 code paths as { name, setup_fn } pairs.
--- Each setup_fn returns a callable that exercises the path once.
local function build_paths()
    local paths = {}

    -- Helper: create a fresh limiter with given config and extract_fn
    local function make_limiter(cfg, extract_fn, incoming_results)
        mocks.reset_incoming_results()
        if incoming_results then
            mocks.set_incoming_results(incoming_results)
        end
        local limiter = mocks.reload_limiter()
        local lim, err = limiter.new(cfg, mocks.make_metrics())
        if not lim then error("limiter.new failed: " .. tostring(err)) end
        lim._set_extract_client_ip = nil  -- not on instance
        limiter._set_extract_client_ip(extract_fn)
        return lim
    end

    -- Path 1: extract_client_ip (FFI operations)
    -- Must enable per_ip so check() proceeds past the short-circuit at line 151
    -- and actually calls extract_client_ip(). The incoming mock allows the request.
    paths[#paths + 1] = {
        name = "extract_client_ip",
        run = function()
            local lim = make_limiter(
                { per_ip = { rate = 100, burst = 100, block_ttl = 60 } },
                mocks.make_ffi_extract_fn(),
                { ["tls-hello-per-ip"] = { 0 } }  -- T1 allow, so check() runs FFI path
            )
            return function() lim:check() end
        end,
    }

    -- Path 2: check_blocklist_hit
    paths[#paths + 1] = {
        name = "check_blocklist_hit",
        run = function()
            local lim = make_limiter(
                { per_ip = { rate = 100, burst = 100, block_ttl = 60 } },
                mocks.make_simple_extract_fn(),
                nil
            )
            -- Seed the blocklist with the mock IP
            mocks.get_blocklist_dict():set(mocks.get_mock_bin_ip(), true, 60)
            return function() lim:check() end
        end,
    }

    -- Path 3: check_per_ip_pass
    paths[#paths + 1] = {
        name = "check_per_ip_pass",
        run = function()
            local lim = make_limiter(
                { per_ip = { rate = 100, burst = 100, block_ttl = 60 } },
                mocks.make_simple_extract_fn(),
                { ["tls-hello-per-ip"] = { 0 } }  -- delay=0, allow
            )
            return function() lim:check() end
        end,
    }

    -- Path 4: check_per_ip_reject
    paths[#paths + 1] = {
        name = "check_per_ip_reject",
        run = function()
            local lim = make_limiter(
                { per_ip = { rate = 100, burst = 100, block_ttl = 60 } },
                mocks.make_simple_extract_fn(),
                { ["tls-hello-per-ip"] = { nil, "rejected" } }
            )
            return function() lim:check() end
        end,
    }

    -- Path 5: check_per_domain_pass
    paths[#paths + 1] = {
        name = "check_per_domain_pass",
        run = function()
            local lim = make_limiter(
                {
                    per_ip = { rate = 100, burst = 100, block_ttl = 60 },
                    per_domain = { rate = 100, burst = 100 },
                },
                mocks.make_simple_extract_fn(),
                {
                    ["tls-hello-per-ip"] = { 0 },          -- T1 pass
                    ["tls-hello-per-domain"] = { 0 },       -- T2 pass
                }
            )
            return function() lim:check() end
        end,
    }

    -- Path 6: check_per_domain_reject
    paths[#paths + 1] = {
        name = "check_per_domain_reject",
        run = function()
            local lim = make_limiter(
                {
                    per_ip = { rate = 100, burst = 100, block_ttl = 60 },
                    per_domain = { rate = 100, burst = 100 },
                },
                mocks.make_simple_extract_fn(),
                {
                    ["tls-hello-per-ip"] = { 0 },                -- T1 pass
                    ["tls-hello-per-domain"] = { nil, "rejected" }, -- T2 reject
                }
            )
            return function() lim:check() end
        end,
    }

    -- Path 7: config_validate
    paths[#paths + 1] = {
        name = "config_validate",
        run = function()
            local config = require("resty.clienthello.ratelimit.config")
            local cfg = {
                per_ip = { rate = 2, burst = 4, block_ttl = 10 },
                per_domain = { rate = 5, burst = 10 },
            }
            return function() config.validate(cfg) end
        end,
    }

    return paths
end

-- ========================================================================
-- CLI Argument Parsing
-- ========================================================================

local function parse_args()
    local format = "human"
    local i = 1
    while i <= #arg do
        if arg[i] == "--format" then
            i = i + 1
            format = arg[i] or "human"
        end
        i = i + 1
    end
    return { format = format }
end

-- ========================================================================
-- Main
-- ========================================================================

local function main()
    local opts = parse_args()

    -- Set up mocks before loading the rate limiter
    mocks.setup_shared_dicts()
    mocks.setup_modules()

    -- Build and run all paths
    local paths = build_paths()
    local results = {}
    for _, path in ipairs(paths) do
        local func = path.run()
        results[#results + 1] = check_path(path.name, func)
    end

    -- Format and print
    local formatter = format_human
    if opts.format == "json" then
        formatter = format_json
    elseif opts.format == "tap" then
        formatter = format_tap
    end
    print(formatter(results))

    -- Exit code: only fail on aborts, not on no_traces
    for _, r in ipairs(results) do
        if r.status == "aborted" then
            os.exit(1)
        end
    end
    os.exit(0)
end

main()
```

- [ ] **Step 2: Commit**

```bash
git add bench/jit_trace.lua
git commit -m "bench: add JIT trace analysis script with all paths and formatters"
```

---

### Task 3: Docker and Makefile Integration

**Files:**
- Create: `bench/Dockerfile`
- Create: `docker-compose.bench.yml`
- Modify: `Makefile`

- [ ] **Step 1: Create bench/Dockerfile**

```dockerfile
FROM openresty/openresty:jammy

COPY lib/ /usr/local/openresty/site/lualib/
COPY bench/ /bench/

WORKDIR /bench
ENTRYPOINT ["resty", "jit_trace.lua"]
```

- [ ] **Step 2: Create docker-compose.bench.yml**

```yaml
services:
  bench-jit:
    build:
      context: .
      dockerfile: bench/Dockerfile
```

- [ ] **Step 3: Add Makefile targets and update clean**

Add to the `.PHONY` line: `bench-jit bench-jit-json bench-jit-tap`

Add these targets after the `openresty-integration` target:

```makefile
bench-jit:
	docker compose -f docker-compose.bench.yml run --rm bench-jit

bench-jit-json:
	docker compose -f docker-compose.bench.yml run --rm bench-jit --format json

bench-jit-tap:
	docker compose -f docker-compose.bench.yml run --rm bench-jit --format tap
```

Add this line at the beginning of the `clean` target (before existing lines):

```makefile
	docker compose -f docker-compose.bench.yml down -v 2>/dev/null || true
```

- [ ] **Step 4: Commit**

```bash
git add bench/Dockerfile docker-compose.bench.yml Makefile
git commit -m "bench: add Docker and Makefile integration for JIT trace analysis"
```

---

### Task 4: End-to-End Verification

- [ ] **Step 1: Run make bench-jit and verify human-readable output**

```bash
make bench-jit
```

Expected: Human-readable table showing 7 paths with their JIT compilation status. Exit code 0 if all paths compile, 1 if any abort.

- [ ] **Step 2: Run make bench-jit-json and verify JSON output**

```bash
make bench-jit-json
```

Expected: Valid JSON with `summary` and `paths` arrays. `summary.total` should be 7.

- [ ] **Step 3: Run make bench-jit-tap and verify TAP output**

```bash
make bench-jit-tap
```

Expected: TAP version 13 output with `1..7` plan line and `ok`/`not ok` lines for each path.

- [ ] **Step 4: Verify exit code propagation**

```bash
make bench-jit; echo "Exit code: $?"
```

Expected: Exit code 0 if all paths compiled, 1 if any aborted. The exit code propagates through Docker.

- [ ] **Step 5: Review any trace aborts and determine if they are expected**

If any paths show ABORT status, investigate:
- Check the abort reason (NYI, etc.)
- Determine if the abort is in mock code vs. library code
- If in mock code: acceptable, note in output
- If in library code: this is a real finding — the benchmark is working as intended

- [ ] **Step 6: Commit any fixes from verification**

```bash
git add -A
git commit -m "bench: fix issues found during JIT trace verification"
```

Only if fixes were needed.
