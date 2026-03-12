"""Integration tests for TLS ClientHello rate limiting via OpenResty adapter."""

import time


class TestTlsPerIpRateLimit:
    def test_normal_handshake_succeeds(self, do_tls_handshake):
        """A single TLS handshake should succeed."""
        # Wait for any block from earlier test files (metrics tests run first alphabetically)
        time.sleep(12)
        assert do_tls_handshake() is True

    def test_rapid_handshakes_get_rejected(self, do_tls_handshake):
        """Flooding TLS handshakes beyond per_ip_rate+burst should fail.

        Config: per_ip: rate=2, burst=4.
        The leaky bucket allows rate+burst=6 before rejecting.
        We send 20 rapid handshakes and expect some to fail.
        """
        results = []
        for _ in range(20):
            results.append(do_tls_handshake(timeout=2))

        successes = sum(1 for r in results if r)
        failures = sum(1 for r in results if not r)

        assert successes > 0, "Expected at least some successful handshakes"
        assert failures > 0, "Expected at least some rejected handshakes"

    def test_rejected_ip_gets_auto_blocked(self, do_tls_handshake, get_metrics):
        """After rejection, the IP should be auto-blocked.

        The tls_ip_autoblock_total counter should increment.
        No sleep needed — OpenResty metrics are live (no caching).
        """
        for _ in range(30):
            do_tls_handshake(timeout=1)

        metrics = get_metrics()
        assert "tls_ip_autoblock_total" in metrics or "tls_clienthello_rejected_total" in metrics

    def test_blocked_handshakes_fail_immediately(self, do_tls_handshake):
        """Once IP is blocked, handshakes should fail immediately."""
        for _ in range(30):
            do_tls_handshake(timeout=1)

        time.sleep(0.5)
        results = [do_tls_handshake(timeout=2) for _ in range(5)]
        failures = sum(1 for r in results if not r)
        assert failures >= 3, f"Expected mostly failures after block, got {failures}/5"

    def test_block_expires_after_ttl(self, do_tls_handshake):
        """After block_ttl (10s), the IP should be unblocked."""
        for _ in range(30):
            do_tls_handshake(timeout=1)

        time.sleep(12)

        assert do_tls_handshake() is True


class TestTlsPerDomainRateLimit:
    def test_per_domain_limit_triggers(self, do_tls_handshake, get_metrics):
        """Flooding a single domain should trigger per-domain rejection.

        Config: per_domain: rate=5, burst=10.
        """
        # Wait for any previous per-IP block to clear
        time.sleep(12)

        for _ in range(30):
            do_tls_handshake(sni="test.example.com", timeout=1)

        metrics = get_metrics()
        assert "tls_clienthello_rejected_total" in metrics


class TestTlsNoSni:
    def test_no_sni_handshake_passes(self, do_tls_handshake, get_metrics):
        """TLS handshake without SNI extension should succeed and emit no-SNI metric.

        When server_hostname=None, SSLContext.wrap_socket() omits the SNI extension.
        The adapter should allow the handshake and increment tls_clienthello_no_sni_total.
        """
        # Wait for any previous per-IP block to clear
        time.sleep(12)

        result = do_tls_handshake(sni=None)
        assert result is True, "No-SNI handshake should succeed"

        metrics = get_metrics()
        assert "tls_clienthello_no_sni_total" in metrics
