local ch = require("spec.core_helpers")

describe("tls-clienthello-limiter.core", function()
    local core, spy

    before_each(function()
        spy = ch.make_metrics_spy()
        ch.setup({sni = "test.example.com"})
    end)

    describe("new()", function()
        it("creates a limiter with defaults", function()
            local core = ch.require_core()
            local lim = core.new()
            assert.is_not_nil(lim)
            assert.is_function(lim.check)
        end)

        it("creates a limiter with custom config", function()
            local core = ch.require_core()
            local lim = core.new({
                per_ip_rate = 10,
                per_ip_burst = 20,
                metrics = spy,
            })
            assert.is_not_nil(lim)
        end)

        it("creates a limiter with no shared dicts gracefully", function()
            ch.setup({dict_per_ip = "nonexistent-a", dict_per_domain = "nonexistent-b", dict_blocklist = "nonexistent-c"})
            local core = ch.require_core()
            local lim = core.new({
                dict_per_ip = "nonexistent-a",
                dict_per_domain = "nonexistent-b",
                dict_blocklist = "nonexistent-c",
            })
            assert.is_not_nil(lim)
        end)
    end)
end)
