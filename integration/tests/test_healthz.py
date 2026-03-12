"""Integration test for the healthz endpoint (Docker healthcheck)."""

import os

import requests


class TestHealthz:
    def test_healthz_endpoint_works(self, metrics_url):
        """The /healthz endpoint (used for Docker healthcheck) should respond."""
        # Healthz is on port 9092, metrics is on 9091 — derive base from env
        healthz_url = "http://" + os.environ.get("APISIX_HTTPS_HOST", "apisix") + ":9092/healthz"
        resp = requests.get(healthz_url, timeout=5)
        assert resp.status_code == 200
        assert resp.text.strip() == "ok"
