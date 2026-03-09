-- Test copy (hardcoded values)
-- =============================================================================
-- custom-metrics.lua — Lightweight Prometheus metrics with TTL-based label expiry
--
-- Stores all metric state in lua_shared_dict "custom-metrics".
-- A background timer prunes label-sets that haven't been touched for
-- `default_ttl` seconds, keeping cardinality bounded even with 500K domains.
--
-- Usage:
--   local metrics = require "custom-metrics"
--   metrics.inc_counter("tls_clienthello_total", {domain="example.com"})
--   metrics.set_gauge("ddos_blocklist_entries", 42, {layer="tls"})
--   metrics.observe_histogram("request_duration_seconds", 0.035, {host="example.com"})
--
-- The /metrics endpoint calls metrics.serialize() to produce text/plain output.
-- =============================================================================

local _M = {}

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------
_M.default_ttl = 300
_M.sweep_interval = 60
_M.dict_name = "custom-metrics"
_M.ts_dict_name = "custom-metrics-timestamps"

-- Histogram bucket boundaries (seconds) — tuned for proxy latencies
_M.histogram_buckets = {
    0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60
}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Build a deterministic storage key from metric name + labels table.
--- Format: "name|k1=v1|k2=v2|..."  (keys sorted)
local function make_key(name, labels)
    if not labels or next(labels) == nil then
        return name
    end
    local parts = {}
    for k, v in pairs(labels) do
        parts[#parts + 1] = k .. "=" .. tostring(v)
    end
    table.sort(parts)
    return name .. "|" .. table.concat(parts, "|")
end

--- Convert a storage key back to {metric_name, {label_pairs...}}
local function parse_key(key)
    local parts = {}
    for seg in key:gmatch("[^|]+") do
        parts[#parts + 1] = seg
    end
    local name = parts[1]
    local labels = {}
    for i = 2, #parts do
        local k, v = parts[i]:match("^(.-)=(.*)$")
        if k then labels[k] = v end
    end
    return name, labels
end

--- Format labels table as Prometheus label string: {k1="v1",k2="v2"}
local function format_labels(labels)
    if not labels or next(labels) == nil then
        return ""
    end
    local parts = {}
    for k, v in pairs(labels) do
        local escaped = tostring(v):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
        parts[#parts + 1] = k .. '="' .. escaped .. '"'
    end
    table.sort(parts)
    return "{" .. table.concat(parts, ",") .. "}"
end

local function touch(key)
    local ts = ngx.shared[_M.ts_dict_name]
    if ts then
        ts:set(key, ngx.now(), _M.default_ttl * 2)
    end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Increment a counter metric by `value` (default 1).
function _M.inc_counter(name, labels, value)
    local dict = ngx.shared[_M.dict_name]
    if not dict then return end
    local key = make_key(name, labels)
    local newval, err = dict:incr(key, value or 1, 0)
    if not newval then
        ngx.log(ngx.ERR, "custom-metrics incr failed: ", err, " key=", key)
    end
    touch(key)
end

--- Set an absolute gauge value.
function _M.set_gauge(name, value, labels)
    local dict = ngx.shared[_M.dict_name]
    if not dict then return end
    local key = make_key(name, labels)
    dict:set(key, value)
    touch(key)
end

--- Increment / decrement a gauge.
function _M.inc_gauge(name, labels, value)
    local dict = ngx.shared[_M.dict_name]
    if not dict then return end
    local key = make_key(name, labels)
    dict:incr(key, value or 1, 0)
    touch(key)
end

--- Record a histogram observation.
--- Creates _bucket, _sum, _count keys.
function _M.observe_histogram(name, value, labels)
    local dict = ngx.shared[_M.dict_name]
    if not dict then return end

    -- _sum
    local sum_key = make_key(name .. "_sum", labels)
    dict:incr(sum_key, value, 0)
    touch(sum_key)

    -- _count
    local count_key = make_key(name .. "_count", labels)
    dict:incr(count_key, 1, 0)
    touch(count_key)

    -- buckets
    for _, le in ipairs(_M.histogram_buckets) do
        if value <= le then
            local blabels = {}
            if labels then
                for k, v in pairs(labels) do blabels[k] = v end
            end
            blabels["le"] = tostring(le)
            local bkey = make_key(name .. "_bucket", blabels)
            dict:incr(bkey, 1, 0)
            touch(bkey)
        end
    end
    -- +Inf bucket (always incremented)
    local inf_labels = {}
    if labels then
        for k, v in pairs(labels) do inf_labels[k] = v end
    end
    inf_labels["le"] = "+Inf"
    local inf_key = make_key(name .. "_bucket", inf_labels)
    dict:incr(inf_key, 1, 0)
    touch(inf_key)
end

-- ---------------------------------------------------------------------------
-- Serialization — produce text/plain Prometheus exposition format
-- ---------------------------------------------------------------------------
function _M.serialize()
    local dict = ngx.shared[_M.dict_name]
    if not dict then return "# no metrics dict\n" end

    local keys = dict:get_keys(0)  -- 0 = all keys
    if not keys or #keys == 0 then
        return "# no metrics\n"
    end

    -- Group by metric name for TYPE lines
    local by_name = {}
    for _, key in ipairs(keys) do
        local name, labels = parse_key(key)
        local val = dict:get(key)
        if val then
            if not by_name[name] then
                by_name[name] = {}
            end
            by_name[name][#by_name[name] + 1] = {
                labels = labels,
                value = val,
            }
        end
    end

    local lines = {}
    local sorted_names = {}
    for name in pairs(by_name) do
        sorted_names[#sorted_names + 1] = name
    end
    table.sort(sorted_names)

    for _, name in ipairs(sorted_names) do
        local entries = by_name[name]

        -- Infer TYPE
        local mtype = "gauge"
        if name:match("_total$") then
            mtype = "counter"
        elseif name:match("_bucket$") or name:match("_sum$") or name:match("_count$") then
            mtype = "histogram"
        end

        -- Only emit TYPE for the base name (not _sum/_count/_bucket)
        local base = name:gsub("_bucket$", ""):gsub("_sum$", ""):gsub("_count$", "")
        if base == name or mtype ~= "histogram" then
            lines[#lines + 1] = "# TYPE " .. name .. " " .. mtype
        end

        for _, entry in ipairs(entries) do
            lines[#lines + 1] = name .. format_labels(entry.labels) .. " " .. tostring(entry.value)
        end
    end

    lines[#lines + 1] = ""
    return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- TTL sweep — called by init_worker timer
-- ---------------------------------------------------------------------------
function _M.sweep_expired()
    local dict = ngx.shared[_M.dict_name]
    local ts   = ngx.shared[_M.ts_dict_name]
    if not dict or not ts then return end

    local now = ngx.now()
    local keys = dict:get_keys(0)
    local pruned = 0

    for _, key in ipairs(keys) do
        local last_touch = ts:get(key)
        if not last_touch or (now - last_touch) > _M.default_ttl then
            dict:delete(key)
            ts:delete(key)
            pruned = pruned + 1
        end
    end

    if pruned > 0 then
        ngx.log(ngx.INFO, "custom-metrics sweep: pruned ", pruned, " expired label-sets")
    end
end

--- Call once from init_worker to start the background sweeper.
--- @param ttl number|nil  Override default_ttl (seconds)
--- @param interval number|nil  Override sweep_interval (seconds)
function _M.start_sweeper(ttl, interval)
    if ttl then _M.default_ttl = ttl end
    if interval then _M.sweep_interval = interval end

    local ok, err = ngx.timer.every(_M.sweep_interval, function(premature)
        if premature then return end
        local pok, perr = pcall(_M.sweep_expired)
        if not pok then
            ngx.log(ngx.ERR, "custom-metrics sweep error: ", perr)
        end
    end)
    if not ok then
        ngx.log(ngx.ERR, "failed to start custom-metrics sweeper: ", err)
    end
end

return _M
