import os
import ssl
import socket

import pytest
import requests


OPENRESTY_HTTPS_HOST = os.environ.get("OPENRESTY_HTTPS_HOST", "openresty")
OPENRESTY_HTTPS_PORT = int(os.environ.get("OPENRESTY_HTTPS_PORT", "443"))
OPENRESTY_METRICS_URL = os.environ.get(
    "OPENRESTY_METRICS_URL", "http://openresty:9092/metrics"
)
TEST_DOMAIN = os.environ.get("TEST_DOMAIN", "test.example.com")
CERT_PATH = "/certs/server.crt"


@pytest.fixture(scope="session")
def openresty_https_host():
    return OPENRESTY_HTTPS_HOST


@pytest.fixture(scope="session")
def openresty_https_port():
    return OPENRESTY_HTTPS_PORT


@pytest.fixture(scope="session")
def metrics_url():
    return OPENRESTY_METRICS_URL


@pytest.fixture(scope="session")
def test_domain():
    return TEST_DOMAIN


def tls_handshake(host, port, sni, timeout=5):
    """Perform a TLS handshake and return True on success, False on failure.

    If sni is None, performs handshake without SNI extension.
    """
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
def do_tls_handshake(openresty_https_host, openresty_https_port):
    """Returns a callable that performs a TLS handshake to OpenResty.

    Pass sni=None for no-SNI handshake.
    """
    def _handshake(sni=TEST_DOMAIN, timeout=5):
        return tls_handshake(openresty_https_host, openresty_https_port, sni, timeout=timeout)
    return _handshake


def fetch_metrics(url=None):
    """Fetch and return the raw metrics text from the prometheus endpoint."""
    resp = requests.get(url or OPENRESTY_METRICS_URL, timeout=5)
    resp.raise_for_status()
    return resp.text


@pytest.fixture
def get_metrics(metrics_url):
    """Returns a callable that fetches metrics text."""
    def _fetch():
        return fetch_metrics(metrics_url)
    return _fetch
