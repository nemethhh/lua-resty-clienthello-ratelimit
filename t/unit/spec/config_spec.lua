local helpers = require("spec.helpers")

describe("resty.clienthello.ratelimit.config", function()
    local config

    before_each(function()
        helpers.setup({})
        package.loaded["resty.clienthello.ratelimit.config"] = nil
        config = require("resty.clienthello.ratelimit.config")
    end)

    describe("validate()", function()
        describe("valid configs", function()
            it("accepts both tiers", function()
                local cfg, err = config.validate({
                    per_ip = { rate = 2, burst = 4, block_ttl = 10 },
                    per_domain = { rate = 5, burst = 10 },
                })
                assert.is_nil(err)
                assert.is_not_nil(cfg)
                assert.are.equal(2, cfg.per_ip.rate)
                assert.are.equal(4, cfg.per_ip.burst)
                assert.are.equal(10, cfg.per_ip.block_ttl)
                assert.are.equal(5, cfg.per_domain.rate)
                assert.are.equal(10, cfg.per_domain.burst)
            end)

            it("accepts per_ip only", function()
                local cfg, err = config.validate({
                    per_ip = { rate = 2, burst = 4, block_ttl = 10 },
                })
                assert.is_nil(err)
                assert.is_not_nil(cfg.per_ip)
                assert.is_nil(cfg.per_domain)
            end)

            it("accepts per_domain only", function()
                local cfg, err = config.validate({
                    per_domain = { rate = 5, burst = 10 },
                })
                assert.is_nil(err)
                assert.is_nil(cfg.per_ip)
                assert.is_not_nil(cfg.per_domain)
            end)

            it("accepts float values", function()
                local cfg, err = config.validate({
                    per_ip = { rate = 2.5, burst = 4.0, block_ttl = 10.5 },
                })
                assert.is_nil(err)
                assert.are.equal(2.5, cfg.per_ip.rate)
            end)

            it("accepts burst = 0", function()
                local cfg, err = config.validate({
                    per_ip = { rate = 2, burst = 0, block_ttl = 10 },
                })
                assert.is_nil(err)
                assert.are.equal(0, cfg.per_ip.burst)
            end)

            it("returns a new table, not the input", function()
                local input = {
                    per_ip = { rate = 2, burst = 4, block_ttl = 10 },
                }
                local cfg, err = config.validate(input)
                assert.is_nil(err)
                assert.are_not.equal(input, cfg)
                assert.are_not.equal(input.per_ip, cfg.per_ip)
            end)
        end)

        describe("warnings", function()
            it("warns when no tiers configured (nil opts)", function()
                local cfg, err = config.validate(nil)
                assert.is_nil(err)
                assert.is_not_nil(cfg)
                assert.are.equal(1, #cfg.warnings)
                assert.truthy(cfg.warnings[1]:find("no rate limit"))
            end)

            it("warns when no tiers configured (empty table)", function()
                local cfg, err = config.validate({})
                assert.is_nil(err)
                assert.are.equal(1, #cfg.warnings)
            end)

            it("returns empty warnings list when tiers configured", function()
                local cfg, err = config.validate({
                    per_ip = { rate = 2, burst = 4, block_ttl = 10 },
                })
                assert.is_nil(err)
                assert.are.equal(0, #cfg.warnings)
            end)
        end)

        describe("error: old flat config", function()
            it("rejects per_ip_rate at top level", function()
                local cfg, err = config.validate({ per_ip_rate = 2 })
                assert.is_nil(cfg)
                assert.truthy(err:find("flat config keys"))
                assert.truthy(err:find("no longer supported"))
            end)

            it("rejects per_domain_rate at top level", function()
                local cfg, err = config.validate({ per_domain_rate = 5 })
                assert.is_nil(cfg)
                assert.truthy(err:find("flat config keys"))
            end)

            it("rejects block_ttl at top level", function()
                local cfg, err = config.validate({ block_ttl = 10 })
                assert.is_nil(cfg)
                assert.truthy(err:find("flat config keys"))
            end)
        end)

        describe("error: unknown keys", function()
            it("rejects unknown top-level keys", function()
                local cfg, err = config.validate({ foo = "bar" })
                assert.is_nil(cfg)
                assert.truthy(err:find("unknown"))
            end)

            it("rejects unknown keys in per_ip", function()
                local cfg, err = config.validate({
                    per_ip = { rate = 2, burst = 4, block_ttl = 10, foo = 1 },
                })
                assert.is_nil(cfg)
                assert.truthy(err:find("unknown"))
            end)

            it("rejects unknown keys in per_domain", function()
                local cfg, err = config.validate({
                    per_domain = { rate = 5, burst = 10, foo = 1 },
                })
                assert.is_nil(cfg)
                assert.truthy(err:find("unknown"))
            end)
        end)

        describe("error: missing required fields", function()
            it("rejects per_ip missing rate", function()
                local cfg, err = config.validate({
                    per_ip = { burst = 4, block_ttl = 10 },
                })
                assert.is_nil(cfg)
                assert.truthy(err:find("rate"))
            end)

            it("rejects per_ip missing burst", function()
                local cfg, err = config.validate({
                    per_ip = { rate = 2, block_ttl = 10 },
                })
                assert.is_nil(cfg)
                assert.truthy(err:find("burst"))
            end)

            it("rejects per_ip missing block_ttl", function()
                local cfg, err = config.validate({
                    per_ip = { rate = 2, burst = 4 },
                })
                assert.is_nil(cfg)
                assert.truthy(err:find("block_ttl"))
            end)

            it("rejects per_domain missing rate", function()
                local cfg, err = config.validate({
                    per_domain = { burst = 10 },
                })
                assert.is_nil(cfg)
                assert.truthy(err:find("rate"))
            end)

            it("rejects per_domain missing burst", function()
                local cfg, err = config.validate({
                    per_domain = { rate = 5 },
                })
                assert.is_nil(cfg)
                assert.truthy(err:find("burst"))
            end)

            it("rejects empty per_ip table", function()
                local cfg, err = config.validate({ per_ip = {} })
                assert.is_nil(cfg)
            end)

            it("rejects empty per_domain table", function()
                local cfg, err = config.validate({ per_domain = {} })
                assert.is_nil(cfg)
            end)
        end)

        describe("error: invalid types", function()
            it("rejects non-table opts", function()
                local cfg, err = config.validate("bad")
                assert.is_nil(cfg)
                assert.truthy(err:find("table"))
            end)

            it("rejects non-table per_ip", function()
                local cfg, err = config.validate({ per_ip = "bad" })
                assert.is_nil(cfg)
                assert.truthy(err:find("table"))
            end)

            it("rejects non-number rate", function()
                local cfg, err = config.validate({
                    per_ip = { rate = "fast", burst = 4, block_ttl = 10 },
                })
                assert.is_nil(cfg)
                assert.truthy(err:find("number"))
            end)
        end)

        describe("error: out of range", function()
            it("rejects rate <= 0", function()
                local cfg, err = config.validate({
                    per_ip = { rate = 0, burst = 4, block_ttl = 10 },
                })
                assert.is_nil(cfg)
                assert.truthy(err:find("rate"))
            end)

            it("rejects negative rate", function()
                local cfg, err = config.validate({
                    per_ip = { rate = -1, burst = 4, block_ttl = 10 },
                })
                assert.is_nil(cfg)
            end)

            it("rejects negative burst", function()
                local cfg, err = config.validate({
                    per_ip = { rate = 2, burst = -1, block_ttl = 10 },
                })
                assert.is_nil(cfg)
            end)

            it("rejects block_ttl <= 0", function()
                local cfg, err = config.validate({
                    per_ip = { rate = 2, burst = 4, block_ttl = 0 },
                })
                assert.is_nil(cfg)
            end)
        end)
    end)
end)
