local helpers = require("spec.helpers")

describe("custom-metrics", function()
    local metrics

    before_each(function()
        helpers.setup({"custom-metrics", "custom-metrics-timestamps"})
        metrics = require("custom-metrics")
    end)

    -- =====================================================================
    -- inc_counter
    -- =====================================================================
    describe("inc_counter", function()
        it("increments a counter with no labels", function()
            metrics.inc_counter("requests_total")
            metrics.inc_counter("requests_total")

            local dict = helpers.get_dict("custom-metrics")
            assert.are.equal(2, dict:get("requests_total"))
        end)

        it("increments a counter by a custom value", function()
            metrics.inc_counter("bytes_total", nil, 512)

            local dict = helpers.get_dict("custom-metrics")
            assert.are.equal(512, dict:get("bytes_total"))
        end)

        it("increments a counter with labels", function()
            metrics.inc_counter("tls_total", {domain = "example.com"})
            metrics.inc_counter("tls_total", {domain = "other.com"})
            metrics.inc_counter("tls_total", {domain = "example.com"})

            local dict = helpers.get_dict("custom-metrics")
            assert.are.equal(2, dict:get("tls_total|domain=example.com"))
            assert.are.equal(1, dict:get("tls_total|domain=other.com"))
        end)

        it("sorts label keys deterministically", function()
            metrics.inc_counter("multi", {z = "1", a = "2"})

            local dict = helpers.get_dict("custom-metrics")
            -- key should be "multi|a=2|z=1" (sorted)
            assert.are.equal(1, dict:get("multi|a=2|z=1"))
            assert.is_nil(dict:get("multi|z=1|a=2"))
        end)

        it("touches the timestamp dict", function()
            metrics.inc_counter("touched_total")

            local ts = helpers.get_dict("custom-metrics-timestamps")
            assert.is_not_nil(ts:get("touched_total"))
        end)
    end)

    -- =====================================================================
    -- set_gauge / inc_gauge
    -- =====================================================================
    describe("set_gauge", function()
        it("sets an absolute gauge value", function()
            metrics.set_gauge("connections", 42)

            local dict = helpers.get_dict("custom-metrics")
            assert.are.equal(42, dict:get("connections"))
        end)

        it("sets gauge with labels", function()
            metrics.set_gauge("dict_size", 1024, {dict = "my-dict"})

            local dict = helpers.get_dict("custom-metrics")
            assert.are.equal(1024, dict:get("dict_size|dict=my-dict"))
        end)

        it("overwrites previous value", function()
            metrics.set_gauge("connections", 42)
            metrics.set_gauge("connections", 10)

            local dict = helpers.get_dict("custom-metrics")
            assert.are.equal(10, dict:get("connections"))
        end)
    end)

    describe("inc_gauge", function()
        it("increments a gauge", function()
            metrics.inc_gauge("active", nil, 1)
            metrics.inc_gauge("active", nil, 1)
            metrics.inc_gauge("active", nil, -1)

            local dict = helpers.get_dict("custom-metrics")
            assert.are.equal(1, dict:get("active"))
        end)
    end)

    -- =====================================================================
    -- observe_histogram
    -- =====================================================================
    describe("observe_histogram", function()
        it("creates _sum, _count, and _bucket keys", function()
            metrics.observe_histogram("latency", 0.05, {host = "a.com"})

            local dict = helpers.get_dict("custom-metrics")

            -- _sum and _count
            assert.are.equal(0.05, dict:get("latency_sum|host=a.com"))
            assert.are.equal(1, dict:get("latency_count|host=a.com"))

            -- +Inf bucket always incremented
            assert.are.equal(1, dict:get("latency_bucket|host=a.com|le=+Inf"))

            -- 0.05 should fall into 0.05, 0.1, 0.25, ... buckets
            assert.are.equal(1, dict:get("latency_bucket|host=a.com|le=0.05"))
            assert.are.equal(1, dict:get("latency_bucket|host=a.com|le=0.1"))

            -- should NOT be in 0.025 bucket (value 0.05 > 0.025)
            assert.is_nil(dict:get("latency_bucket|host=a.com|le=0.025"))
        end)

        it("accumulates multiple observations", function()
            metrics.observe_histogram("latency", 0.01)
            metrics.observe_histogram("latency", 0.5)

            local dict = helpers.get_dict("custom-metrics")
            assert.are.equal(0.51, dict:get("latency_sum"))
            assert.are.equal(2, dict:get("latency_count"))
        end)
    end)

    -- =====================================================================
    -- serialize
    -- =====================================================================
    describe("serialize", function()
        it("returns placeholder when no metrics exist", function()
            local out = metrics.serialize()
            assert.matches("no metrics", out)
        end)

        it("produces valid Prometheus text for counters", function()
            metrics.inc_counter("http_requests_total", {method = "GET"})
            metrics.inc_counter("http_requests_total", {method = "POST"}, 3)

            local out = metrics.serialize()
            assert.matches('# TYPE http_requests_total counter', out, 1, true)
            assert.matches('http_requests_total{method="GET"} 1', out, 1, true)
            assert.matches('http_requests_total{method="POST"} 3', out, 1, true)
        end)

        it("produces valid Prometheus text for gauges", function()
            metrics.set_gauge("temperature", 36.6)

            local out = metrics.serialize()
            assert.matches("# TYPE temperature gauge", out, 1, true)
            assert.matches("temperature 36.6", out, 1, true)
        end)

        it("escapes label values with backslash, quote, newline", function()
            metrics.inc_counter("escaped_total", {path = 'a"b\\c\nd'})

            local out = metrics.serialize()
            -- Prometheus escaping: \" \\ \n
            assert.matches('path="a\\"b\\\\c\\n', out, 1, true)
        end)

        it("sorts metric names alphabetically", function()
            metrics.inc_counter("zzz_total")
            metrics.inc_counter("aaa_total")

            local out = metrics.serialize()
            local aaa_pos = out:find("aaa_total")
            local zzz_pos = out:find("zzz_total")
            assert.is_true(aaa_pos < zzz_pos)
        end)
    end)

    -- =====================================================================
    -- sweep_expired
    -- =====================================================================
    describe("sweep_expired", function()
        it("prunes keys older than default_ttl", function()
            metrics.inc_counter("old_total")
            metrics.inc_counter("fresh_total")

            -- Advance time past TTL for "old_total" only
            -- Touch "fresh_total" again after advancing
            helpers.advance_time(metrics.default_ttl + 1)
            metrics.inc_counter("fresh_total")

            metrics.sweep_expired()

            local dict = helpers.get_dict("custom-metrics")
            assert.is_nil(dict:get("old_total"))
            assert.are.equal(2, dict:get("fresh_total"))
        end)

        it("does not prune keys within TTL", function()
            metrics.inc_counter("recent_total")
            helpers.advance_time(10)  -- well within TTL

            metrics.sweep_expired()

            local dict = helpers.get_dict("custom-metrics")
            assert.are.equal(1, dict:get("recent_total"))
        end)
    end)

    -- =====================================================================
    -- start_sweeper
    -- =====================================================================
    describe("start_sweeper", function()
        it("registers a recurring timer", function()
            metrics.start_sweeper()

            local timers = helpers.get_timers()
            assert.are.equal(1, #timers)
            assert.are.equal(metrics.sweep_interval, timers[1].interval)
        end)

        it("allows overriding ttl and interval", function()
            metrics.start_sweeper(60, 10)

            assert.are.equal(60, metrics.default_ttl)
            assert.are.equal(10, metrics.sweep_interval)
        end)
    end)
end)
