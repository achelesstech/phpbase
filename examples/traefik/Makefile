# =============================================================================
# Traefik — operations
# =============================================================================
.DEFAULT_GOAL := help
SHELL         := /bin/bash
COMPOSE       ?= docker compose
NETWORK       ?= proxy

.PHONY: help init token htpasswd up down restart reload logs logs-access \
        ps check config doctor cf-ips certs backup pull shell

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n",$$1,$$2}'

# -----------------------------------------------------------------------------
init: ## One-time: create the proxy network and local directories
	@docker network inspect $(NETWORK) >/dev/null 2>&1 \
	  || docker network create $(NETWORK)
	@mkdir -p certs secrets
	@chmod 700 certs secrets
	@# DOCKER_GID differs between hosts, so fill it in from this one.
	@test -f .env || { \
	   gid="$$(stat -c %g /var/run/docker.sock)" || exit 1; \
	   sed "s/^DOCKER_GID=$$/DOCKER_GID=$$gid/" .env.example > .env; \
	   echo "created .env with DOCKER_GID=$$gid — set TRAEFIK_DOMAIN in it"; }
	@echo "next: make token && make htpasswd USER=admin"

token: ## Store the Cloudflare DNS API token (prompts, not echoed)
	@read -rsp "Cloudflare DNS API token: " t; echo; \
	 printf '%s' "$$t" > secrets/cf_dns_api_token; \
	 chmod 600 secrets/cf_dns_api_token; \
	 echo "wrote secrets/cf_dns_api_token"

htpasswd: ## Add/replace a dashboard user:  make htpasswd USER=admin
	@test -n "$(USER)" || { echo "usage: make htpasswd USER=admin"; exit 1; }
	@mkdir -p secrets
	@touch secrets/.htpasswd
	@docker run --rm -i httpd:2.4-alpine htpasswd -nB "$(USER)" \
	  >> secrets/.htpasswd
	@chmod 600 secrets/.htpasswd
	@echo "added $(USER) to secrets/.htpasswd"

# -----------------------------------------------------------------------------
up: check ## Validate, then start
	$(COMPOSE) up -d

down: ## Stop and remove
	$(COMPOSE) down

restart: check ## Reload STATIC config (config/traefik.yml)
	$(COMPOSE) restart traefik

reload: ## Reminder: dynamic/ needs no restart
	@echo "dynamic/*.yml is watched — changes are already live."
	@echo "Only config/traefik.yml needs 'make restart'."
	@$(COMPOSE) logs --tail=20 traefik | grep -i "configuration" || true

pull: ## Pull newer images
	$(COMPOSE) pull

# -----------------------------------------------------------------------------
logs: ## Follow the Traefik log
	$(COMPOSE) logs -f --tail=100 traefik

logs-access: ## Follow access logs only (needs jq)
	$(COMPOSE) logs -f --tail=200 traefik \
	  | grep -F '"DownstreamStatus"' \
	  | jq -r '[.ClientHost,.RequestHost,.RequestPath,.DownstreamStatus,.Duration]|@tsv' 2>/dev/null \
	  || $(COMPOSE) logs -f --tail=200 traefik

ps: ## Container status
	$(COMPOSE) ps

shell: ## Shell inside the Traefik container
	$(COMPOSE) exec traefik sh

config: ## Render the compose file with .env applied
	$(COMPOSE) config

# -----------------------------------------------------------------------------
check: ## Parse every config file, then boot Traefik and fail on any error log
	@./scripts/check-config.sh

doctor: ## Diagnose a running Traefik (forwarded headers, TLS, certs, rate limit)
	@./scripts/traefik-doctor.sh

cf-ips: ## Check the committed Cloudflare ranges against cloudflare.com/ips
	@./scripts/cf-ips.sh

certs: ## List issued certificates; fail if any expire within 21 days
	@./scripts/acme-certs.sh

backup: ## Tar the ACME store and secrets (contains private keys — handle it)
	@tar czf "traefik-state-$$(date +%F).tgz" certs secrets
	@chmod 600 "traefik-state-$$(date +%F).tgz"
	@echo "wrote traefik-state-$$(date +%F).tgz — store it somewhere encrypted"
