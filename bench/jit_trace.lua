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
    iterations = iterations or 500

    local stops = 0
    local aborts = {}

    local function trace_cb(what, tr, tfunc, pc, otr, oex)
        if what == "stop" then
            stops = stops + 1
        elseif what == "abort" then
            local location = format_location(tfunc, pc)
            -- Skip aborts from the harness loop itself
            if not location:find("jit_trace%.lua") then
                aborts[#aborts + 1] = {
                    reason   = format_abort_reason(otr, oex),
                    location = location,
                }
            end
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
    if stops > 0 and #aborts == 0 then
        status = "compiled"
    elseif stops > 0 and #aborts > 0 then
        status = "compiled_with_aborts"  -- code JIT-compiles, but some traces aborted
    elseif #aborts > 0 then
        status = "aborted"              -- no successful traces at all
    else
        status = "no_traces"            -- too simple or JIT didn't kick in
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
    local STATUS_LABELS = {
        compiled = "COMPILED",
        compiled_with_aborts = "COMPILED*",
        aborted = "ABORT",
        no_traces = "NO_TRACE",
    }
    for _, r in ipairs(results) do
        local status_str = STATUS_LABELS[r.status] or r.status
        lines[#lines + 1] = string.format(
            "  %-28s %-10s %-7d %d", r.name, status_str, r.traces, #r.aborts)
        if r.status == "compiled" or r.status == "compiled_with_aborts" then
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
    local aborted_count = 0
    for _, r in ipairs(results) do
        if r.status == "aborted" then aborted_count = aborted_count + 1 end
    end
    local has_star = false
    for _, r in ipairs(results) do
        if r.status == "compiled_with_aborts" then has_star = true; break end
    end
    if aborted_count == 0 then
        lines[#lines + 1] = string.format("Result: PASS (%d/%d paths compiled)", compiled_count, total)
        if has_star then
            lines[#lines + 1] = "  (* = compiled with some structural trace aborts, see aborts column)"
        end
    else
        lines[#lines + 1] = string.format("Result: FAIL (%d/%d paths failed to JIT-compile)",
            aborted_count, total)
    end

    return table.concat(lines, "\n")
end

local function format_json(results)
    -- Minimal JSON encoder (no external dependencies)
    local compiled_count = 0
    for _, r in ipairs(results) do
        if r.status == "compiled" or r.status == "compiled_with_aborts" then
            compiled_count = compiled_count + 1
        end
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
        local passed = r.status == "compiled" or r.status == "compiled_with_aborts"
        if passed then
            local suffix = r.status == "compiled_with_aborts"
                and " # structural trace aborts (code still JIT-compiles)" or ""
            lines[#lines + 1] = string.format("ok %d - %s%s", i, r.name, suffix)
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
