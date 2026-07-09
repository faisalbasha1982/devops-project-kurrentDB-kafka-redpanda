.DEFAULT_GOAL := help
COMPOSE := docker compose
TB_IMAGE := ghcr.io/tigerbeetle/tigerbeetle:latest
TB_FILE  := data/tigerbeetle/0_0.tigerbeetle

.PHONY: help init up down ps logs urls verify tb-repl clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

init: ## One-time: pull images and format the TigerBeetle data file
	$(COMPOSE) pull
	@mkdir -p data/tigerbeetle
	@if [ ! -f $(TB_FILE) ]; then \
	  echo ">> formatting TigerBeetle data file"; \
	  docker run --rm --security-opt seccomp=unconfined \
	    -v "$$(pwd)/data/tigerbeetle:/data" $(TB_IMAGE) \
	    format --cluster=0 --replica=0 --replica-count=1 --development /data/0_0.tigerbeetle; \
	else \
	  echo ">> TigerBeetle already formatted ($(TB_FILE)) — skipping"; \
	fi

up: ## Start the whole platform in the background
	$(COMPOSE) up -d

down: ## Stop everything (keeps data volumes)
	$(COMPOSE) down

ps: ## Show container status
	$(COMPOSE) ps

logs: ## Tail logs (use: make logs S=kurrentdb)
	$(COMPOSE) logs -f $(S)

urls: ## Print the local URLs for each component
	@echo "KurrentDB Admin UI     http://localhost:2113"
	@echo "TigerBeetle (gRPC)     localhost:3000"
	@echo "Redpanda Console       http://localhost:8080"
	@echo "Redpanda Kafka         localhost:19092"
	@echo "Redpanda SchemaReg      http://localhost:18081"
	@echo "Prometheus             http://localhost:9090"
	@echo "Grafana                http://localhost:3001  (admin/admin)"

verify: ## Quick health check of each component
	@echo "-- KurrentDB /health/live"; curl -fsS http://localhost:2113/health/live && echo "  OK" || echo "  DOWN"
	@echo "-- Redpanda cluster health"; docker exec aequor-redpanda rpk cluster health || true
	@echo "-- Prometheus ready"; curl -fsS http://localhost:9090/-/ready && echo || echo "  DOWN"
	@echo "-- Grafana health"; curl -fsS http://localhost:3001/api/health && echo || echo "  DOWN"
	@echo "-- TigerBeetle: run 'make tb-repl' and try the demo below"

tb-repl: ## Open the TigerBeetle CLI REPL against the running cluster
	docker exec -it aequor-tigerbeetle /tigerbeetle repl --cluster=0 --addresses=3000

clean: ## Stop everything AND delete all data (volumes + TigerBeetle file)
	$(COMPOSE) down -v
	rm -f $(TB_FILE)
	@echo ">> all data removed"
