.PHONY: unit integration certs all clean

all: unit integration

unit:
	docker compose -f docker-compose.unit.yml up --build --abort-on-container-exit --exit-code-from unit-tests
	docker compose -f docker-compose.unit.yml down -v

certs: integration/certs/server.crt

integration/certs/server.crt:
	openssl req -x509 -newkey rsa:2048 -keyout integration/certs/server.key \
		-out integration/certs/server.crt -days 365 -nodes \
		-subj "/CN=test.example.com" \
		-addext "subjectAltName=DNS:test.example.com,DNS:*.test.example.com"

integration: certs
	docker compose -f docker-compose.integration.yml up --build --abort-on-container-exit --exit-code-from test-runner
	docker compose -f docker-compose.integration.yml down -v

clean:
	docker compose -f docker-compose.unit.yml down -v 2>/dev/null || true
	docker compose -f docker-compose.integration.yml down -v 2>/dev/null || true
	rm -f integration/certs/server.crt integration/certs/server.key
