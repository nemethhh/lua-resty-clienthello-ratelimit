"""Integration tests for the custom metrics endpoint (:9092/metrics)."""

import requests


class TestCustomMetricsEndpoint:
    def test_metrics_endpoint_responds(self, metrics_url):
        """The custom metrics server should be up and responding."""
        resp = requests.get(metrics_url, timeout=5)
        assert resp.status_code == 200
        assert "text/plain" in resp.headers.get("Content-Type", "")

    def test_shared_dict_gauges_present(self, metrics_url):
        """Shared dict utilisation gauges should appear in metrics output."""
        resp = requests.get(metrics_url, timeout=5)
        body = resp.text

        assert "ddos_shdict_capacity_bytes" in body
        assert "ddos_shdict_free_bytes" in body
        assert "ddos_shdict_used_ratio" in body

    def test_metrics_key_count_gauge(self, metrics_url):
        """The ddos_metrics_key_count gauge should be present."""
        resp = requests.get(metrics_url, timeout=5)
        assert "ddos_metrics_key_count" in resp.text

    def test_blocklist_entries_gauge(self, metrics_url):
        """The ddos_blocklist_entries gauge should be present."""
        resp = requests.get(metrics_url, timeout=5)
        assert "ddos_blocklist_entries" in resp.text

    def test_metrics_after_tls_handshake(self, do_tls_handshake, metrics_url):
        """After a TLS handshake, tls_clienthello_total should appear."""
        # Perform a successful handshake
        assert do_tls_handshake() is True

        resp = requests.get(metrics_url, timeout=5)
        assert "tls_clienthello_total" in resp.text
