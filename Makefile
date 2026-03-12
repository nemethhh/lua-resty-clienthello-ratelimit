.PHONY: unit integration openresty-integration certs all clean

all: unit integration openresty-integration

unit:
	docker compose -f docker-compose.unit.yml up --build --abort-on-container-exit --exit-code-from unit-tests
	docker compose -f docker-compose.unit.yml down -v

certs: integration/certs/server.crt

integration/certs/server.crt:
	bash integration/generate-conf.sh

integration: certs
	docker compose -f docker-compose.integration.yml up --build --abort-on-container-exit --exit-code-from test-runner
	docker compose -f docker-compose.integration.yml down -v

openresty-integration: certs
	docker compose -f docker-compose.openresty-integration.yml up --build --abort-on-container-exit --exit-code-from test-runner
	docker compose -f docker-compose.openresty-integration.yml down -v

clean:
	docker compose -f docker-compose.unit.yml down -v 2>/dev/null || true
	docker compose -f docker-compose.integration.yml down -v 2>/dev/null || true
	docker compose -f docker-compose.openresty-integration.yml down -v 2>/dev/null || true
	rm -f integration/certs/server.crt integration/certs/server.key integration/conf/apisix.yaml
