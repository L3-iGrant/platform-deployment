# =============================================================================
# Organisation Wallet Suite - Docker Compose Makefile
# =============================================================================

.PHONY: help start stop restart logs status clean pull

# Show help - automatically generated from comments
.DEFAULT_GOAL := help

help: ## Show this help message
	@echo "========================================================================"
	@echo "Organisation Wallet Suite by iGrant.io - Docker Compose"
	@echo "========================================================================"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# =============================================================================
# Main Commands
# =============================================================================

start: ## Start all services
	@echo "Starting all services..."
	@if [ -f env.sh ]; then \
		source ./env.sh && docker compose up -d; \
	else \
		docker compose up -d; \
	fi
	@echo "All services started successfully!"
	@echo ""
	@echo "Services available at:"
	@echo "  - API:                  http://localhost:8080"
	@echo "  - Keycloak:             http://localhost:8082"
	@echo "  - Organisation Wallet:  http://localhost:8090"
	@echo "  - Enterprise Dashboard: http://localhost:3000"
	@echo "  - Vault Facade:         http://localhost:8081"
	@echo "  - NATS:                 localhost:4222"
	@echo "  - NATS Monitor:         http://localhost:8222"

stop: ## Stop all services
	@echo "Stopping all services..."
	@docker compose stop
	@echo "All services stopped successfully!"

restart: ## Restart all services
	@echo "Restarting all services..."
	@docker compose restart
	@echo "All services restarted successfully!"

down: ## Stop and remove all containers
	@echo "Stopping and removing all containers..."
	@docker compose down
	@echo "All containers removed successfully!"

logs: ## View logs from all services (use CTRL+C to exit)
	@docker compose logs -f

status: ## Show status of all services
	@docker compose ps

pull: ## Pull latest images
	@echo "Pulling latest images..."
	@if [ -f env.sh ]; then \
		source ./env.sh && docker compose pull; \
	else \
		docker compose pull; \
	fi
	@echo "Images pulled successfully!"

# =============================================================================
# Individual Service Commands
# =============================================================================

postgres-start: ## Start PostgreSQL
	@docker compose up -d postgres

postgres-stop: ## Stop PostgreSQL
	@docker compose stop postgres

postgres-logs: ## View PostgreSQL logs
	@docker compose logs -f postgres

keycloak-start: ## Start Keycloak
	@docker compose up -d keycloak

keycloak-stop: ## Stop Keycloak
	@docker compose stop keycloak

keycloak-logs: ## View Keycloak logs
	@docker compose logs -f keycloak

mongo-start: ## Start MongoDB
	@docker compose up -d mongo

mongo-stop: ## Stop MongoDB
	@docker compose stop mongo

mongo-logs: ## View MongoDB logs
	@docker compose logs -f mongo

nats-start: ## Start NATS
	@docker compose up -d nats

nats-stop: ## Stop NATS
	@docker compose stop nats

nats-logs: ## View NATS logs
	@docker compose logs -f nats

vault-facade-start: ## Start Vault Facade
	@docker compose up -d vault-facade

vault-facade-stop: ## Stop Vault Facade
	@docker compose stop vault-facade

vault-facade-logs: ## View Vault Facade logs
	@docker compose logs -f vault-facade

api-start: ## Start API
	@docker compose up -d api

api-stop: ## Stop API
	@docker compose stop api

api-logs: ## View API logs
	@docker compose logs -f api

webhook-start: ## Start Webhook
	@docker compose up -d webhook

webhook-stop: ## Stop Webhook
	@docker compose stop webhook

webhook-logs: ## View Webhook logs
	@docker compose logs -f webhook

ows-start: ## Start Organisation Wallet
	@docker compose up -d organisation-wallet

ows-stop: ## Stop Organisation Wallet
	@docker compose stop organisation-wallet

ows-logs: ## View Organisation Wallet logs
	@docker compose logs -f organisation-wallet

dashboard-start: ## Start Enterprise Dashboard
	@docker compose up -d enterprise-dashboard

dashboard-stop: ## Stop Enterprise Dashboard
	@docker compose stop enterprise-dashboard

dashboard-logs: ## View Enterprise Dashboard logs
	@docker compose logs -f enterprise-dashboard

# =============================================================================
# Database Commands
# =============================================================================

postgres-shell: ## Connect to PostgreSQL shell
	@docker compose exec postgres psql -U $${POSTGRES_USERNAME:-dbadmin} -d $${POSTGRES_DATABASE:-kcdb}

mongo-shell: ## Connect to MongoDB shell
	@docker compose exec mongo mongosh -u $${MONGO_USERNAME:-dbadmin} -p $${MONGO_PASSWORD:-dbadmin} --authenticationDatabase admin

# =============================================================================
# Cleanup Commands
# =============================================================================

clean: ## Remove all containers and volumes (WARNING: destroys data)
	@echo "WARNING: This will remove all containers and volumes!"
	@read -p "Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ] && \
		docker compose down -v && \
		echo "Cleanup completed!" || \
		echo "Cleanup cancelled."

clean-images: ## Remove all project images
	@echo "Removing project images..."
	@docker compose down --rmi all
	@echo "Images removed successfully!"

prune: ## Remove unused Docker resources
	@echo "Pruning unused Docker resources..."
	@docker system prune -f
	@echo "Prune completed!"
