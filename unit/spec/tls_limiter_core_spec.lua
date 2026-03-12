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

    describe("check()", function()
        it("returns false when no request context", function()
            ch.set_mock_request(false)
            local core = ch.require_core()
            local lim = core.new({metrics = spy})
            local rejected, reason = lim:check()
            assert.is_false(rejected)
            assert.is_nil(reason)
        end)

        it("returns true,'blocklist' for blocked IP", function()
            ch.setup({sni = "test.example.com"})
            local core = ch.require_core()
            local lim = core.new({metrics = spy})
            -- Pre-populate blocklist
            local dict = ngx.shared["tls-ip-blocklist"]
            local bin_ip = string.char(10, 0, 0, 1)
            dict:set(bin_ip, true, 60)
            local rejected, reason = lim:check()
            assert.is_true(rejected)
            assert.are.equal("blocklist", reason)
            assert.is_not_nil(spy.find("tls_clienthello_blocked_total"))
        end)

        it("returns false for a normal request", function()
            ch.setup({sni = "test.example.com"})
            local core = ch.require_core()
            local lim = core.new({metrics = spy})
            local rejected = lim:check()
            assert.is_false(rejected)
            assert.is_not_nil(spy.find("tls_clienthello_passed_total"))
        end)

        it("returns true,'per_ip' after exceeding per-IP rate+burst", function()
            ch.setup({sni = "test.example.com"})
            local core = ch.require_core()
            local lim = core.new({
                per_ip_rate = 2,
                per_ip_burst = 4,
                metrics = spy,
            })
            -- rate+burst = 6, so 7th call should be rejected
            for i = 1, 6 do
                local rejected = lim:check()
                assert.is_false(rejected, "call " .. i .. " should pass")
            end
            local rejected, reason = lim:check()
            assert.is_true(rejected)
            assert.are.equal("per_ip", reason)
            -- Should have auto-blocked
            assert.is_not_nil(spy.find("tls_ip_autoblock_total"))
        end)

        it("returns true,'per_domain' after exceeding per-domain rate+burst", function()
            ch.setup({sni = "test.example.com"})
            local core = ch.require_core()
            -- High per-IP limit so it doesn't trigger first
            local lim = core.new({
                per_ip_rate = 100,
                per_ip_burst = 100,
                per_domain_rate = 2,
                per_domain_burst = 2,
                metrics = spy,
            })
            for i = 1, 4 do
                lim:check()
            end
            local rejected, reason = lim:check()
            assert.is_true(rejected)
            assert.are.equal("per_domain", reason)
        end)

        it("emits tls_clienthello_no_sni_total when no SNI", function()
            ch.setup({sni = nil})
            local core = ch.require_core()
            local lim = core.new({metrics = spy})
            lim:check()
            assert.is_not_nil(spy.find("tls_clienthello_no_sni_total"))
        end)

        it("works without metrics adapter (nil)", function()
            ch.setup({sni = "test.example.com"})
            local core = ch.require_core()
            local lim = core.new()  -- no metrics
            local rejected = lim:check()
            assert.is_false(rejected)
        end)

        it("after auto-block, subsequent calls hit blocklist", function()
            ch.setup({sni = "test.example.com"})
            local core = ch.require_core()
            local lim = core.new({
                per_ip_rate = 1,
                per_ip_burst = 1,
                metrics = spy,
            })
            -- Exhaust: 2 pass, 3rd rejected + auto-blocked
            lim:check()
            lim:check()
            lim:check()
            -- Now should hit blocklist path
            spy = ch.make_metrics_spy()
            lim.metrics = spy
            local rejected, reason = lim:check()
            assert.is_true(rejected)
            assert.are.equal("blocklist", reason)
        end)
    end)
end)
