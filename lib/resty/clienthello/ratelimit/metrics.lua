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
