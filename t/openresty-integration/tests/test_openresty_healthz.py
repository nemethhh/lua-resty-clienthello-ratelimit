"""Integration test for the OpenResty healthz endpoint (Docker healthcheck)."""

import os

import requests


class TestHealthz:
    def test_healthz_endpoint_works(self):
        """The /healthz endpoint (used for Docker healthcheck) should respond."""
        host = os.environ.get("OPENRESTY_HTTPS_HOST", "openresty")
        healthz_url = f"http://{host}:9092/healthz"
        resp = requests.get(healthz_url, timeout=5)
        assert resp.status_code == 200
        assert resp.text.strip() == "ok"
