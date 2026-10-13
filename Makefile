.PHONY: up down load fixture test integration fmt train-sequential train-distributed
up:
	docker compose up -d --build --wait
down:
	docker compose down
load:
	docker compose --profile jobs run --build --rm loader -config configs/demo.json
fixture:
	docker compose --profile jobs run --build --rm loader -config configs/fixture.json
test:
	docker compose --profile tools run --rm dev go test -race ./...
integration:
	docker compose --profile tools run --rm dev go test -race -count=1 ./tests/integration
fmt:
	docker compose --profile tools run --rm dev gofmt -w cmd internal tests/integration web
train-sequential:
	docker compose --profile jobs run --build --rm trainer -mode sequential -config configs/training.json
train-distributed:
	docker compose up -d --build --scale worker=2 --wait
	docker compose --profile jobs run --build --rm trainer -mode distributed -config configs/training.json
