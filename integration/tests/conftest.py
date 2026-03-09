import os
import ssl
import socket
import time

import pytest
import requests


APISIX_HTTP_URL = os.environ.get("APISIX_HTTP_URL", "http://apisix:80")
APISIX_HTTPS_HOST = os.environ.get("APISIX_HTTPS_HOST", "apisix")
APISIX_HTTPS_PORT = int(os.environ.get("APISIX_HTTPS_PORT", "443"))
APISIX_METRICS_URL = os.environ.get("APISIX_METRICS_URL", "http://apisix:9092/metrics")
TEST_DOMAIN = os.environ.get("TEST_DOMAIN", "test.example.com")
CERT_PATH = "/certs/server.crt"


@pytest.fixture(scope="session")
def apisix_http_url():
    return APISIX_HTTP_URL


@pytest.fixture(scope="session")
def apisix_https_host():
    return APISIX_HTTPS_HOST


@pytest.fixture(scope="session")
def apisix_https_port():
    return APISIX_HTTPS_PORT


@pytest.fixture(scope="session")
def metrics_url():
    return APISIX_METRICS_URL


@pytest.fixture(scope="session")
def test_domain():
    return TEST_DOMAIN


@pytest.fixture(scope="session")
def ssl_context():
    """SSL context that trusts the self-signed test cert."""
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.load_verify_locations(CERT_PATH)
    return ctx


def tls_handshake(host, port, sni, ctx=None, timeout=5):
    """Perform a TLS handshake and return True on success, False on failure."""
    if ctx is None:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    ssl_sock = ctx.wrap_socket(sock, server_hostname=sni)
    try:
        ssl_sock.connect((host, port))
        return True
    except (ssl.SSLError, ConnectionResetError, ConnectionRefusedError, OSError):
        return False
    finally:
        ssl_sock.close()


@pytest.fixture(scope="session")
def do_tls_handshake(apisix_https_host, apisix_https_port):
    """Returns a callable that performs a TLS handshake to APISIX."""
    def _handshake(sni=TEST_DOMAIN, timeout=5):
        return tls_handshake(apisix_https_host, apisix_https_port, sni, timeout=timeout)
    return _handshake


def fetch_metrics(url=None):
    """Fetch and return the raw metrics text from the custom metrics endpoint."""
    resp = requests.get(url or APISIX_METRICS_URL, timeout=5)
    resp.raise_for_status()
    return resp.text


@pytest.fixture
def get_metrics(metrics_url):
    """Returns a callable that fetches metrics text."""
    def _fetch():
        return fetch_metrics(metrics_url)
    return _fetch
