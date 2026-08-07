# =============================================================================
# Portainer CE — operations
# =============================================================================
.DEFAULT_GOAL := help
SHELL         := /bin/bash
COMPOSE       ?= docker compose
NETWORK       ?= proxy

.PHONY: help init password up down restart logs ps check doctor backup pull \
        adopt version

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}'

# -----------------------------------------------------------------------------
init: ## One-time: .env, encryption key, admin password
	@docker network inspect $(NETWORK) >/dev/null 2>&1 \
	  || { echo "no '$(NETWORK)' network — start Traefik first"; exit 1; }
	@mkdir -p secrets && chmod 700 secrets
	@test -f .env || { cp .env.example .env; echo "created .env — set PORTAINER_DOMAIN"; }
	@if [ ! -s secrets/encryption_key ]; then \
	   openssl rand -base64 32 | tr -d '\n' > secrets/encryption_key; \
	   chmod 600 secrets/encryption_key; \
	   echo "generated secrets/encryption_key"; \
	   echo "  ^ BACK THIS UP. An encrypted store without its key does not open."; \
	 else echo "secrets/encryption_key already exists — left alone"; fi
	@$(MAKE) --no-print-directory password

password: ## Set the initial admin password (prompts, not echoed)
	@if [ -s secrets/admin_password ]; then \
	   echo "secrets/admin_password exists. Portainer only reads it when creating"; \
	   echo "the admin user, so changing it now does nothing — rotate in the UI."; \
	   exit 0; \
	 fi
	@mkdir -p secrets
	@read -rsp "Admin password (12+ chars): " p; echo; \
	 if [ "$${#p}" -lt 12 ]; then echo "too short — Portainer requires 12+"; exit 1; fi; \
	 read -rsp "Again: " q; echo; \
	 if [ "$$p" != "$$q" ]; then echo "they do not match"; exit 1; fi; \
	 printf '%s' "$$p" > secrets/admin_password; \
	 chmod 600 secrets/admin_password; \
	 echo "wrote secrets/admin_password"

# -----------------------------------------------------------------------------
up: check ## Validate, then start
	$(COMPOSE) up -d

down: ## Stop and remove (the volume survives)
	$(COMPOSE) down

restart: ## Restart
	$(COMPOSE) restart

pull: ## Pull a newer image
	$(COMPOSE) pull

logs: ## Follow the log
	$(COMPOSE) logs -f --tail=100 portainer

ps: ## Container status
	$(COMPOSE) ps

version: ## Which Portainer is running
	@$(COMPOSE) logs portainer 2>/dev/null \
	  | grep -o '"version":"[^"]*"' | tail -1 | sed 's/^/  /' \
	  || echo "  not running"

# -----------------------------------------------------------------------------
check: ## Validate before starting
	@./scripts/check-config.sh

doctor: ## Diagnose a running Portainer
	@./scripts/portainer-doctor.sh

backup: ## Tar the data volume AND the encryption key
	@./scripts/backup.sh

adopt: ## Show how to migrate an existing `docker run` install
	@echo "The official guide's container uses a volume named 'portainer_data',"
	@echo "which is the same name this compose file uses — so it is adopted"
	@echo "automatically. To switch over:"
	@echo
	@echo "  docker stop portainer && docker rm portainer"
	@echo "  make init && make up"
	@echo
	@echo "Users, environments and settings all live in the volume and survive."
	@echo "Two things to know:"
	@echo "  - 'make password' will be skipped: an admin already exists, and"
	@echo "    Portainer logs 'administrator user defined, skipping admin"
	@echo "    password related flags'. The file must still be present."
	@echo "  - do NOT enable the encryption key on an existing store without"
	@echo "    backing it up first."
