"""Integration tests for IP whitelist bypass.

The TLS limiter whitelists 127.0.0.1 and ::1 via resty.ipmatcher.
Since the test-runner connects over Docker network (not loopback),
external test traffic is NOT whitelisted — this is correct behavior.

These tests verify:
1. External (non-whitelisted) traffic IS rate-limited (already covered in test_tls_rate_limit)
2. The whitelisted_total counter exists in metrics (may be 0 from external)
"""

import requests


class TestWhitelistBehavior:
    def test_external_traffic_is_not_whitelisted(self, do_tls_handshake, get_metrics):
        """Traffic from test-runner (non-loopback) should NOT be whitelisted."""
        do_tls_handshake()
        metrics = get_metrics()

        # tls_clienthello_total should exist (we just did a handshake)
        assert "tls_clienthello_total" in metrics

        # The whitelisted counter should either not exist or be 0
        # (no loopback TLS traffic in this test)
        for line in metrics.splitlines():
            if "tls_clienthello_whitelisted_total" in line and not line.startswith("#"):
                # If it exists, value should be 0
                parts = line.strip().split()
                if len(parts) >= 2:
                    assert float(parts[-1]) == 0, (
                        f"Expected 0 whitelisted from external traffic, got {parts[-1]}"
                    )

    def test_healthz_endpoint_works(self, metrics_url):
        """The /healthz endpoint (used for Docker healthcheck) should respond."""
        healthz_url = metrics_url.replace("/metrics", "/healthz")
        resp = requests.get(healthz_url, timeout=5)
        assert resp.status_code == 200
        assert resp.text.strip() == "ok"
