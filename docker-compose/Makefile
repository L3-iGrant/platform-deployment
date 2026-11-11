# =============================================================================
# The iGrant.io platform for Docker Compose. README.md has the procedure.
# =============================================================================

COMPOSE ?= docker compose
# openbao-init runs as your user, so that secrets/openbao/init.json belongs
# to you.
export HOST_UID := $(shell id -u)
export HOST_GID := $(shell id -g)
# The Helm chart of this repository (make nats-config).
CHART_DIR ?= ..

.DEFAULT_GOAL := help
.PHONY: help env secrets check up status logs down reset platform-operator platform-set-operator \
	platform-grant-admin platform-status admin organisation db-shell openbao-status nats-config

help: ## Show the targets
	@echo "iGrant.io platform - Docker Compose (README.md has the procedure)"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# --- Installation ----------------------------------------------------------------

env: ## Step 2: make .env from .env.example (keeps a .env that exists)
	@if [ -f .env ]; then echo "env: .env exists (kept)"; \
	else cp .env.example .env && echo "env: wrote .env: set your values, then run make secrets"; fi

secrets: ## Step 3: make all secrets and keys in secrets/ (keeps the files that exist; prints no value)
	@./secrets.sh

check: ## Step 4: check .env, secrets/ and the Compose files (no container starts)
	@./check.sh

up: check ## Step 5: start the platform (after make check)
	$(COMPOSE) up -d
	@echo "up: started. make status shows the state of the services."

status: ## Show the state of the services (also the one-shot services that stopped)
	$(COMPOSE) ps -a --format 'table {{.Service}}\t{{.State}}\t{{.Status}}'

logs: ## Follow the logs of all services (CTRL+C stops)
	$(COMPOSE) logs -f

down: ## Stop and remove the containers (the data in the volumes stays)
	$(COMPOSE) down

# reset deletes the data: the volumes (databases, NATS, OpenBao, files) and
# secrets/openbao/init.json (the next start initialises a new OpenBao). The
# other files of secrets/ stay.
reset: ## Remove the containers AND all data (asks first)
	@read -r -p "This deletes all data of the platform. Type yes to continue: " answer; \
	if [ "$$answer" = yes ]; then \
	  $(COMPOSE) down -v && rm -f secrets/openbao/init.json && echo "reset: done"; \
	else echo "reset: cancelled"; fi

# --- Operation -------------------------------------------------------------------

API_COMMAND = $(COMPOSE) exec -T api /app/bin/igrant-api
API_CONFIG = --config /etc/igrant-api/config.yaml
ORGANISATION_TYPE ?= Technology

# The platform operator of a new installation: the platform operator
# organisation and its first admin with the platform admin right, in one
# command (onboard bootstrap-platform; it also makes the organisation type).
# An installation has one platform operator organisation; its platform
# admins make the other organisations in the dashboard. The command is
# idempotent. The password is read from the terminal and goes to the
# command on standard input: it is never an argument. It needs 15
# characters or more and at least one special character, and the admin sets
# a new password at the first login.
platform-operator: ## Step 8: make the platform operator organisation and its first platform admin: make platform-operator ADMIN_EMAIL=... ADMIN_NAME=... ORG_NAME=... ORG_LOCATION=... ORG_POLICY_URL=... (asks for the password)
	@test -n "$(ADMIN_EMAIL)" && test -n "$(ADMIN_NAME)" && test -n "$(ORG_NAME)" && test -n "$(ORG_LOCATION)" && test -n "$(ORG_POLICY_URL)" || \
		{ echo "platform-operator: set ADMIN_EMAIL, ADMIN_NAME, ORG_NAME, ORG_LOCATION and ORG_POLICY_URL" >&2; exit 1; }
	@stty -echo 2>/dev/null; printf 'First password of %s (15 characters or more, with at least one special character; the input is hidden): ' "$(ADMIN_EMAIL)"; \
	IFS= read -r password; stty echo 2>/dev/null; echo; \
	printf '%s' "$$password" | $(API_COMMAND) onboard bootstrap-platform \
		--admin-email "$(ADMIN_EMAIL)" --admin-name "$(ADMIN_NAME)" --password-file - \
		--organisation-name "$(ORG_NAME)" --type "$(ORGANISATION_TYPE)" \
		--location "$(ORG_LOCATION)" --policy-url "$(ORG_POLICY_URL)" $(API_CONFIG)

# The platform operator of an installation that exists (README.md, "Change
# to the release with the platform operator"). The commands are idempotent.
platform-set-operator: ## An installation that exists: give an organisation that exists the platform operator mark: make platform-set-operator ORGANISATION_ID=...
	@test -n "$(ORGANISATION_ID)" || { echo "platform-set-operator: set ORGANISATION_ID" >&2; exit 1; }
	@$(API_COMMAND) platform set-operator --organisation-id "$(ORGANISATION_ID)" $(API_CONFIG) </dev/null

platform-grant-admin: ## An installation that exists: give an admin of the platform operator organisation the platform admin right: make platform-grant-admin ADMIN_EMAIL=...
	@test -n "$(ADMIN_EMAIL)" || { echo "platform-grant-admin: set ADMIN_EMAIL" >&2; exit 1; }
	@$(API_COMMAND) platform grant-admin --email "$(ADMIN_EMAIL)" $(API_CONFIG) </dev/null

platform-status: ## Show the platform operator organisation and the platform admins (reads only)
	@$(API_COMMAND) platform status $(API_CONFIG) </dev/null

# An admin and an organisation WITHOUT the platform operator mark (the
# targets of the earlier releases; the dashboard login refuses an admin
# without an organisation). For a new installation, use platform-operator.
# The commands are idempotent.
admin: ## Earlier releases: make an admin without an organisation: make admin ADMIN_EMAIL=... ADMIN_NAME=... ADMIN_PHONE=... (asks for the password)
	@test -n "$(ADMIN_EMAIL)" && test -n "$(ADMIN_NAME)" && test -n "$(ADMIN_PHONE)" || \
		{ echo "admin: set ADMIN_EMAIL, ADMIN_NAME and ADMIN_PHONE" >&2; exit 1; }
	@$(COMPOSE) exec -T api /app/bin/igrant-api onboard create-organisation-type \
		--type "$(ORGANISATION_TYPE)" --config /etc/igrant-api/config.yaml </dev/null
	@stty -echo 2>/dev/null; printf 'Password of %s (12 characters or more, with at least one special character; the input is hidden): ' "$(ADMIN_EMAIL)"; \
	IFS= read -r password; stty echo 2>/dev/null; echo; \
	printf '%s' "$$password" | $(COMPOSE) exec -T api /app/bin/igrant-api onboard register-admin \
		--email "$(ADMIN_EMAIL)" --name "$(ADMIN_NAME)" --phone "$(ADMIN_PHONE)" \
		--password-file - --config /etc/igrant-api/config.yaml

organisation: ## Earlier releases: make the organisation of that admin (no platform operator mark): make organisation ADMIN_EMAIL=... ORG_NAME=... ORG_LOCATION=... ORG_POLICY_URL=... [ORG_DESCRIPTION=...]
	@test -n "$(ADMIN_EMAIL)" && test -n "$(ORG_NAME)" && test -n "$(ORG_LOCATION)" && test -n "$(ORG_POLICY_URL)" || \
		{ echo "organisation: set ADMIN_EMAIL, ORG_NAME, ORG_LOCATION and ORG_POLICY_URL" >&2; exit 1; }
	@$(COMPOSE) exec -T api /app/bin/igrant-api onboard create-organisation \
		--admin-email "$(ADMIN_EMAIL)" --name "$(ORG_NAME)" --type "$(ORGANISATION_TYPE)" \
		--location "$(ORG_LOCATION)" --policy-url "$(ORG_POLICY_URL)" --description "$(ORG_DESCRIPTION)" \
		--config /etc/igrant-api/config.yaml

db-shell: ## Open the SQL shell of the database server as the admin user
	$(COMPOSE) exec postgres psql -U postgres -d postgres

openbao-status: ## Show the seal status of OpenBao
	$(COMPOSE) exec openbao bao status

# --- Maintainers -----------------------------------------------------------------

# The NATS users and their subjects come from the Helm chart (helper
# ow.nats.users), so that the chart and Docker Compose have the same users.
# Run this target after a change of the NATS users of the chart (needs helm).
NATS_USERS := api:API apiWebhook:API_WEBHOOK consent:CONSENT walletConfig:WALLET_CONFIG \
	walletService:WALLET_SERVICE walletWorker:WALLET_WORKER
nats-config: ## Maintainers: write config/nats/users.conf from the NATS users of the Helm chart
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
