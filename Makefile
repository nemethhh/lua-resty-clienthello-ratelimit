.PHONY: unit integration openresty-integration certs all clean bench-jit bench-jit-json bench-jit-tap

all: unit integration openresty-integration

unit:
	docker compose -f docker-compose.unit.yml up --build --abort-on-container-exit --exit-code-from unit-tests
	docker compose -f docker-compose.unit.yml down -v

certs: t/integration/certs/server.crt

t/integration/certs/server.crt:
	bash t/integration/generate-conf.sh

integration: certs
	docker compose -f docker-compose.integration.yml up --build --abort-on-container-exit --exit-code-from test-runner
	docker compose -f docker-compose.integration.yml down -v

openresty-integration: certs
	docker compose -f docker-compose.openresty-integration.yml up --build --abort-on-container-exit --exit-code-from test-runner
	docker compose -f docker-compose.openresty-integration.yml down -v

bench-jit:
	docker compose -f docker-compose.bench.yml run --rm bench-jit

bench-jit-json:
	docker compose -f docker-compose.bench.yml run --rm bench-jit --format json

bench-jit-tap:
	docker compose -f docker-compose.bench.yml run --rm bench-jit --format tap

clean:
	docker compose -f docker-compose.bench.yml down -v 2>/dev/null || true
	docker compose -f docker-compose.unit.yml down -v 2>/dev/null || true
	docker compose -f docker-compose.integration.yml down -v 2>/dev/null || true
	docker compose -f docker-compose.openresty-integration.yml down -v 2>/dev/null || true
	rm -f t/integration/certs/server.crt t/integration/certs/server.key t/integration/conf/apisix.yaml
