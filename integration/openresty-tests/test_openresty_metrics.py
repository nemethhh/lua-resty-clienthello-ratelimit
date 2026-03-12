"""Integration tests for OpenResty prometheus metrics endpoint."""

import time


class TestOpenrestyMetrics:
    def test_passed_counter_increments(self, do_tls_handshake, get_metrics):
        """Successful handshakes should increment passed counter.

        No apisix_ prefix — bare metric names from nginx-lua-prometheus.
        """
        # Wait for any blocks to expire
        time.sleep(12)

        do_tls_handshake()
        metrics = get_metrics()
        assert "tls_clienthello_passed_total" in metrics

    def test_blocked_counter_increments(self, do_tls_handshake, get_metrics):
        """After flooding, blocked/rejected counter should appear."""
        for _ in range(30):
            do_tls_handshake(timeout=1)

        metrics = get_metrics()
        assert ("tls_clienthello_blocked_total" in metrics
                or "tls_clienthello_rejected_total" in metrics)
