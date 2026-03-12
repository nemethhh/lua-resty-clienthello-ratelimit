local ch = require("spec.core_helpers")

describe("tls-clienthello-limiter.core", function()
    local spy

    before_each(function()
        spy = ch.make_metrics_spy()
        ch.setup({sni = "test.example.com"})
    end)

    describe("new()", function()
        it("creates a limiter with both tiers", function()
            local core = ch.require_core()
            local lim, err = core.new({
                per_ip = { rate = 2, burst = 4, block_ttl = 10 },
                per_domain = { rate = 5, burst = 10 },
            }, spy)
            assert.is_nil(err)
            assert.is_not_nil(lim)
            assert.is_function(lim.check)
        end)

        it("creates a limiter with per_ip only", function()
            local core = ch.require_core()
            local lim, err = core.new({
                per_ip = { rate = 2, burst = 4, block_ttl = 10 },
            }, spy)
            assert.is_nil(err)
            assert.is_not_nil(lim)
        end)

        it("creates a limiter with per_domain only", function()
            local core = ch.require_core()
            local lim, err = core.new({
                per_domain = { rate = 5, burst = 10 },
            }, spy)
            assert.is_nil(err)
            assert.is_not_nil(lim)
        end)

        it("returns warnings when no tiers configured", function()
            local core = ch.require_core()
            local lim, warnings = core.new({})
            assert.is_not_nil(lim)
            assert.are.equal(1, #warnings)
            assert.truthy(warnings[1]:find("no rate limit"))
        end)

        it("returns nil and error for invalid config", function()
            local core = ch.require_core()
            local lim, err = core.new({ per_ip = { rate = -1, burst = 4, block_ttl = 10 } })
            assert.is_nil(lim)
            assert.is_string(err)
        end)
    end)

    describe("check() with both tiers", function()
        it("returns false when no request context", function()
            ch.set_mock_request(false)
            local core = ch.require_core()
            local lim = core.new({
                per_ip = { rate = 2, burst = 4, block_ttl = 10 },
                per_domain = { rate = 5, burst = 10 },
            }, spy)
            local rejected, reason = lim:check()
            assert.is_false(rejected)
            assert.is_nil(reason)
        end)

        it("returns true,'blocklist' for blocked IP", function()
            local core = ch.require_core()
            local lim = core.new({
                per_ip = { rate = 2, burst = 4, block_ttl = 10 },
                per_domain = { rate = 5, burst = 10 },
            }, spy)
            local dict = ngx.shared["tls-ip-blocklist"]
            local bin_ip = string.char(10, 0, 0, 1)
            dict:set(bin_ip, true, 60)
            local rejected, reason = lim:check()
            assert.is_true(rejected)
            assert.are.equal("blocklist", reason)
            assert.is_not_nil(spy.find("tls_clienthello_blocked_total"))
        end)

        it("returns false for a normal request", function()
            local core = ch.require_core()
            local lim = core.new({
                per_ip = { rate = 2, burst = 4, block_ttl = 10 },
                per_domain = { rate = 5, burst = 10 },
            }, spy)
            local rejected = lim:check()
            assert.is_false(rejected)
            assert.is_not_nil(spy.find("tls_clienthello_passed_total"))
        end)

        it("returns true,'per_ip' after exceeding per-IP rate+burst", function()
            local core = ch.require_core()
            local lim = core.new({
                per_ip = { rate = 2, burst = 4, block_ttl = 10 },
                per_domain = { rate = 100, burst = 100 },
            }, spy)
            for i = 1, 6 do
                local rejected = lim:check()
                assert.is_false(rejected, "call " .. i .. " should pass")
            end
            local rejected, reason = lim:check()
            assert.is_true(rejected)
            assert.are.equal("per_ip", reason)
            assert.is_not_nil(spy.find("tls_ip_autoblock_total"))
        end)

        it("returns true,'per_domain' after exceeding per-domain rate+burst", function()
            local core = ch.require_core()
            local lim = core.new({
                per_ip = { rate = 100, burst = 100, block_ttl = 10 },
                per_domain = { rate = 2, burst = 2 },
            }, spy)
            for i = 1, 4 do
                lim:check()
            end
            local rejected, reason = lim:check()
            assert.is_true(rejected)
            assert.are.equal("per_domain", reason)
        end)

        it("emits tls_clienthello_no_sni_total when no SNI", function()
            ch.setup()
            ch.set_mock_sni(nil)
            local core = ch.require_core()
            local lim = core.new({
                per_ip = { rate = 2, burst = 4, block_ttl = 10 },
                per_domain = { rate = 5, burst = 10 },
            }, spy)
            lim:check()
            assert.is_not_nil(spy.find("tls_clienthello_no_sni_total"))
        end)

        it("works without metrics adapter (nil)", function()
            local core = ch.require_core()
            local lim = core.new({
                per_ip = { rate = 2, burst = 4, block_ttl = 10 },
                per_domain = { rate = 5, burst = 10 },
            })
            local rejected = lim:check()
            assert.is_false(rejected)
        end)

        it("after auto-block, subsequent calls hit blocklist", function()
            local core = ch.require_core()
            local lim = core.new({
                per_ip = { rate = 1, burst = 1, block_ttl = 10 },
                per_domain = { rate = 100, burst = 100 },
            }, spy)
            lim:check()
            lim:check()
            lim:check()
            spy = ch.make_metrics_spy()
            lim.metrics = spy
            local rejected, reason = lim:check()
            assert.is_true(rejected)
            assert.are.equal("blocklist", reason)
        end)
    end)

    describe("check() with per_ip only", function()
        it("skips per_domain tier entirely", function()
            local core = ch.require_core()
            local lim = core.new({
                per_ip = { rate = 2, burst = 4, block_ttl = 10 },
            }, spy)
            local rejected = lim:check()
            assert.is_false(rejected)
            -- Should see per_ip passed but no per_domain passed
            assert.is_not_nil(spy.find("tls_clienthello_passed_total"))
            -- The per_domain tier should not emit anything
            local calls = spy.get_calls()
            for _, c in ipairs(calls) do
                if c.labels and c.labels.layer then
                    assert.are_not.equal("per_domain", c.labels.layer)
                end
            end
        end)

        it("still applies blocklist when per_ip rejects", function()
            local core = ch.require_core()
            local lim = core.new({
                per_ip = { rate = 1, burst = 1, block_ttl = 10 },
            }, spy)
            lim:check()
            lim:check()
            lim:check()  -- should be rejected + auto-blocked
            assert.is_not_nil(spy.find("tls_ip_autoblock_total"))
        end)
    end)

    describe("check() with per_domain only", function()
        it("skips per_ip and blocklist tiers entirely", function()
            local core = ch.require_core()
            local lim = core.new({
                per_domain = { rate = 5, burst = 10 },
            }, spy)
            local rejected = lim:check()
            assert.is_false(rejected)
            -- Should not emit per_ip metrics
            local calls = spy.get_calls()
            for _, c in ipairs(calls) do
                if c.labels and c.labels.layer then
                    assert.are_not.equal("per_ip", c.labels.layer)
                end
                assert.are_not.equal("tls_clienthello_blocked_total", c.name)
                assert.are_not.equal("tls_ip_autoblock_total", c.name)
            end
        end)

        it("does not block IPs (no blocklist)", function()
            local core = ch.require_core()
            -- Even with high traffic, no auto-block since per_ip is disabled
            local lim = core.new({
                per_domain = { rate = 1, burst = 1 },
            }, spy)
            lim:check()
            lim:check()
            lim:check()  -- rejected by per_domain
            assert.is_nil(spy.find("tls_ip_autoblock_total"))
        end)
    end)
end)
