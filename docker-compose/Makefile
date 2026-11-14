# =============================================================================
# The iGrant.io platform on Docker Compose. See README.md for the steps.
# =============================================================================

COMPOSE ?= docker compose
# openbao-init runs as your user, so you own secrets/openbao/init.json.
export HOST_UID := $(shell id -u)
export HOST_GID := $(shell id -g)
# The Helm chart in this repository (used by make nats-config).
CHART_DIR ?= ..

.DEFAULT_GOAL := help
.PHONY: help env secrets configs check up status logs down reset platform-operator \
	platform-grant-admin platform-status db-shell openbao-status nats-config

help: ## Show the targets
	@echo "iGrant.io platform - Docker Compose (README.md has the procedure)"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# --- Installation ----------------------------------------------------------------

env: ## Step 2: create .env from .env.example (keeps an existing .env)
	@if [ -f .env ]; then echo "env: .env exists (kept)"; \
	else cp .env.example .env && echo "env: wrote .env: set your values, then run make secrets"; fi

secrets: ## Step 3: create all secrets and keys in secrets/ (keeps existing files; prints no values)
	@./secrets.sh

# Component configuration files: Compose fills the templates in
# compose.configs.yaml with the values of .env, and render-configs.py writes
# the results to generated/ (a service with a read-only root file system can
# take a config only from a file). make check and make up run this first.
configs: ## Write the component configuration files to generated/ from .env (make check and make up run it)
	@COMPOSE="$(COMPOSE)" python3 -I ./render-configs.py

check: configs ## Step 4: write the configuration files, then check .env, secrets/ and the Compose files (starts no container)
	@./check.sh

# --remove-orphans: removes the services that a new release dropped (for
# example a service that is no longer in the Compose files).
up: check ## Step 5: start the platform (after make check)
	$(COMPOSE) up -d --remove-orphans
	@echo "up: started. make status shows the state of the services."

status: ## Show the state of the services (including the stopped one-shot services)
	$(COMPOSE) ps -a --format 'table {{.Service}}\t{{.State}}\t{{.Status}}'

logs: ## Follow the logs of all services (CTRL+C stops)
	$(COMPOSE) logs -f

down: ## Stop and remove the containers (the data in the volumes is kept)
	$(COMPOSE) down

# reset deletes all data: the volumes (databases, NATS, OpenBao, files) and
# secrets/openbao/init.json, so the next start initialises a new OpenBao.
# The other files in secrets/ are kept.
reset: ## Remove the containers AND all data (asks first)
	@read -r -p "This deletes all data of the platform. Type yes to continue: " answer; \
	if [ "$$answer" = yes ]; then \
	  $(COMPOSE) down -v && rm -f secrets/openbao/init.json && echo "reset: done"; \
	else echo "reset: cancelled"; fi

# --- Operation -------------------------------------------------------------------

API_COMMAND = $(COMPOSE) exec -T api /app/bin/igrant-api
API_CONFIG = --config /etc/igrant-api/config.yaml
ORGANISATION_TYPE ?= Technology

# Sets up the platform operator of a new installation in one command
# (onboard bootstrap-platform): the platform operator organisation, its
# organisation type when missing, and its first admin with the platform
# admin right. An installation has one platform operator organisation; its
# platform admins create the other organisations in the dashboard. The
# command is idempotent. The password is read from the terminal and passed
# on standard input, never as an argument. It needs 15 characters or more
# with at least one special character, and the admin sets a new password at
# the first login.
platform-operator: ## Step 8: create the platform operator organisation and its first platform admin: make platform-operator ADMIN_EMAIL=... ADMIN_NAME=... ORG_NAME=... ORG_LOCATION=... ORG_POLICY_URL=... (asks for the password)
	@test -n "$(ADMIN_EMAIL)" && test -n "$(ADMIN_NAME)" && test -n "$(ORG_NAME)" && test -n "$(ORG_LOCATION)" && test -n "$(ORG_POLICY_URL)" || \
		{ echo "platform-operator: set ADMIN_EMAIL, ADMIN_NAME, ORG_NAME, ORG_LOCATION and ORG_POLICY_URL" >&2; exit 1; }
	@stty -echo 2>/dev/null; printf 'First password of %s (15 characters or more, with at least one special character; the input is hidden): ' "$(ADMIN_EMAIL)"; \
	IFS= read -r password; stty echo 2>/dev/null; echo; \
	printf '%s' "$$password" | $(API_COMMAND) onboard bootstrap-platform \
		--admin-email "$(ADMIN_EMAIL)" --admin-name "$(ADMIN_NAME)" --password-file - \
		--organisation-name "$(ORG_NAME)" --type "$(ORGANISATION_TYPE)" \
		--location "$(ORG_LOCATION)" --policy-url "$(ORG_POLICY_URL)" $(API_CONFIG)

# Recovery when no platform admin can log in (in the dashboard, only a
# platform admin can give the right). Idempotent.
platform-grant-admin: ## Recovery: give the platform admin right to an admin of the platform operator organisation: make platform-grant-admin ADMIN_EMAIL=...
	@test -n "$(ADMIN_EMAIL)" || { echo "platform-grant-admin: set ADMIN_EMAIL" >&2; exit 1; }
	@$(API_COMMAND) platform grant-admin --email "$(ADMIN_EMAIL)" $(API_CONFIG) </dev/null

platform-status: ## Show the platform operator organisation and the platform admins (read only)
	@$(API_COMMAND) platform status $(API_CONFIG) </dev/null

db-shell: ## Open an SQL shell on the database server as the admin user
	$(COMPOSE) exec postgres psql -U postgres -d postgres

openbao-status: ## Show the OpenBao seal status
	$(COMPOSE) exec openbao bao status

# --- Maintainers -----------------------------------------------------------------

# The NATS users and their subjects come from the Helm chart (helper
# ow.nats.users), so the chart and Docker Compose have the same users. Run
# this target after you change the chart's NATS users (needs helm).
NATS_USERS := api:API apiWebhook:API_WEBHOOK consent:CONSENT walletConfig:WALLET_CONFIG \
	walletService:WALLET_SERVICE walletWorker:WALLET_WORKER
nats-config: ## Maintainers: write config/nats/users.conf from the Helm chart's NATS users
	@{ \
	  echo "# Generated by \"make nats-config\" from the Helm chart (templates/nats/configmap.yaml,"; \
	  echo "# helper ow.nats.users). Do not change it by hand: change the chart, then run"; \
	  echo "# the target again. The nkeys are the variables of nkeys.conf (make secrets)."; \
	  echo "include ./nkeys.conf"; \
	  echo ""; \
	  helm template igrant $(CHART_DIR) --show-only templates/nats/configmap.yaml \
	    --set nats.enabled=false,api.enabled=false \
	    --set consent.enabled=false,organisationWallet.enabled=false,enterpriseDashboard.enabled=false \
	    $(foreach user,$(NATS_USERS),--set nats.auth.users.$(firstword $(subst :, ,$(user))).nkey=UNATS_NKEY_$(lastword $(subst :, ,$(user)))) \
	  | awk '/^    authorization \{/ {on = 1} on {print} on && /^    \}$$/ {exit}' \
	  | sed -e 's/^    //' -e 's/"U\(NATS_NKEY_[A-Z_]*\)"/$$\1/g'; \
	} > config/nats/users.conf.tmp
	@grep -q 'nkey: $$NATS_NKEY_WALLET_WORKER' config/nats/users.conf.tmp || { rm -f config/nats/users.conf.tmp; echo "nats-config: helm template gave no users" >&2; exit 1; }
	@mv config/nats/users.conf.tmp config/nats/users.conf
	@echo "nats-config: wrote config/nats/users.conf"
