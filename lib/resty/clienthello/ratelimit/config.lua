-- =============================================================================
-- resty.clienthello.ratelimit.config — Configuration validation (pure function)
-- =============================================================================

local _M = {}

-- Old flat keys that trigger a migration error
local FLAT_KEYS = {
    per_ip_rate = true,
    per_ip_burst = true,
    per_domain_rate = true,
    per_domain_burst = true,
    block_ttl = true,
    dict_per_ip = true,
    dict_per_domain = true,
    dict_blocklist = true,
}

local VALID_TOP_KEYS = {
    per_ip = true,
    per_domain = true,
}

local VALID_PER_IP_KEYS = {
    rate = true,
    burst = true,
    block_ttl = true,
}

local VALID_PER_DOMAIN_KEYS = {
    rate = true,
    burst = true,
}

local function check_unknown_keys(tbl, allowed, prefix)
    for k in pairs(tbl) do
        if not allowed[k] then
            return prefix .. ": unknown key '" .. tostring(k) .. "'"
        end
    end
    return nil
end

local function check_number(val, name, prefix, min_exclusive, min_inclusive)
    if type(val) ~= "number" then
        return prefix .. "." .. name .. " must be a number, got " .. type(val)
    end
    if min_exclusive and val <= 0 then
        return prefix .. "." .. name .. " must be > 0, got " .. val
    end
    if min_inclusive and val < 0 then
        return prefix .. "." .. name .. " must be >= 0, got " .. val
    end
    return nil
end

local function validate_per_ip(t)
    if type(t) ~= "table" then
        return nil, "per_ip must be a table, got " .. type(t)
    end

    local err = check_unknown_keys(t, VALID_PER_IP_KEYS, "per_ip")
    if err then return nil, err end

    for _, field in ipairs({"rate", "burst", "block_ttl"}) do
        if t[field] == nil then
            return nil, "per_ip: missing required field '" .. field .. "'"
        end
    end

    err = check_number(t.rate, "rate", "per_ip", true, false)
    if err then return nil, err end
    err = check_number(t.burst, "burst", "per_ip", false, true)
    if err then return nil, err end
    err = check_number(t.block_ttl, "block_ttl", "per_ip", true, false)
    if err then return nil, err end

    return { rate = t.rate, burst = t.burst, block_ttl = t.block_ttl }
end

local function validate_per_domain(t)
    if type(t) ~= "table" then
        return nil, "per_domain must be a table, got " .. type(t)
    end

    local err = check_unknown_keys(t, VALID_PER_DOMAIN_KEYS, "per_domain")
    if err then return nil, err end

    for _, field in ipairs({"rate", "burst"}) do
        if t[field] == nil then
            return nil, "per_domain: missing required field '" .. field .. "'"
        end
    end

    err = check_number(t.rate, "rate", "per_domain", true, false)
    if err then return nil, err end
    err = check_number(t.burst, "burst", "per_domain", false, true)
    if err then return nil, err end

    return { rate = t.rate, burst = t.burst }
end

--- Validate rate-limit configuration.
--- Pure function: does not log, does not access ngx.
--- @param opts table|nil Raw config from user
--- @return table|nil cfg Validated config with per_ip, per_domain, warnings
--- @return string|nil err Error message on failure
function _M.validate(opts)
    if opts == nil then
        return { per_ip = nil, per_domain = nil, warnings = {"no rate limit tiers configured"} }
    end

    if type(opts) ~= "table" then
        return nil, "opts must be a table, got " .. type(opts)
    end

    -- Detect old flat config keys
    for k in pairs(opts) do
        if FLAT_KEYS[k] then
            return nil, "flat config keys (per_ip_rate, per_ip_burst, per_domain_rate, "
                .. "per_domain_burst, block_ttl, ...) are no longer supported; "
                .. "use nested per_ip = { rate = N, burst = N, block_ttl = N } format"
        end
    end

    -- Check for unknown top-level keys
    local err = check_unknown_keys(opts, VALID_TOP_KEYS, "config")
    if err then return nil, err end

    local result = { per_ip = nil, per_domain = nil, warnings = {} }

    if opts.per_ip ~= nil then
        local validated, verr = validate_per_ip(opts.per_ip)
        if not validated then return nil, verr end
        result.per_ip = validated
    end

    if opts.per_domain ~= nil then
        local validated, verr = validate_per_domain(opts.per_domain)
        if not validated then return nil, verr end
        result.per_domain = validated
    end

    if not result.per_ip and not result.per_domain then
        result.warnings[#result.warnings + 1] = "no rate limit tiers configured"
    end

    return result
end

return _M
