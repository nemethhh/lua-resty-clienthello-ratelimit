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

    it("shares cached vals across counter names for the same labels ref", function()
        local p = make_prometheus_mock()
        local inc = metrics.make_cached_inc_counter(p, nil)
        local labels = {layer = "per_ip"}

        inc("counter_a", labels)
        inc("counter_b", labels)

        local calls = p.get_counter_obj().get_inc_calls()
        assert.are.equal(2, #calls)
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
        -- Second call with a NEW table (different ref, different content)
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
end)
