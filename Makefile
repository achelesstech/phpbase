# =============================================================================
# Makefile — PHP Base Image Builder
# =============================================================================
# Usage:
#   make build-laravel          Build base with Laravel profile
#   make build-drupal           Build base with Drupal profile
#   make build-moodle           Build base with Moodle profile
#   make build-wordpress        Build base with WordPress profile
#   make build-symfony          Build base with Symfony profile
#   make build-mautic           Build base with Mautic profile
#   make build-custom ARGS="--build-arg INSTALL_REDIS=true ..."
#   make build-minimal          Smallest possible image
#
# PHP 8.4 is the default: it satisfies Laravel 13 (8.3+, and 8.4 required by
# 13.3+ Symfony 8 deps), Drupal 11 (8.3+) and Moodle 5.1 (8.2–8.4) at once.
# =============================================================================

REGISTRY   ?= achelesstech
IMAGE_NAME ?= php-base
PHP_VERSION ?= 8.4
# Sortable tag: phpX.Y-YYYYmmdd-HHMM (the old %Y-%d%b format didn't sort)
DATE_TAG   ?= php$(PHP_VERSION)-$(shell date '+%Y%m%d-%H%M')
LATEST_TAG ?= php$(PHP_VERSION)-latest

DOCKER_BUILD = docker buildx build \
	--build-arg PHP_VERSION=$(PHP_VERSION) \
	--load \
	--progress=plain

# ─── Shared base args ────────────────────────────────────────────────────────
COMMON_ARGS = \
	--build-arg INSTALL_COMPOSER=true \
	--build-arg INSTALL_GD=true \
	--build-arg INSTALL_INTL=true

# ─── Profiles ────────────────────────────────────────────────────────────────

# Laravel 13: MySQL/PostgreSQL + Redis, public/ docroot
LARAVEL_ARGS = $(COMMON_ARGS) \
	--build-arg INSTALL_MYSQL=true \
	--build-arg INSTALL_POSTGRESQL=true \
	--build-arg INSTALL_REDIS=true \
	--build-arg APP_PUBLIC_DIR=public \
	--build-arg NGINX_PROFILE=laravel

# Drupal 11: MySQL/PostgreSQL + GD + APCu (class loader / cache chain), web/ docroot
DRUPAL_ARGS = $(COMMON_ARGS) \
	--build-arg INSTALL_MYSQL=true \
	--build-arg INSTALL_POSTGRESQL=true \
	--build-arg INSTALL_APCU=true \
	--build-arg APP_PUBLIC_DIR=web \
	--build-arg NGINX_PROFILE=drupal

# Moodle 5.1: SOAP + LDAP + spellcheck/doc tooling, public/ docroot (5.1
# restructure). XML-RPC removed — no longer required by Moodle.
MOODLE_ARGS = $(COMMON_ARGS) \
	--build-arg INSTALL_MYSQL=true \
	--build-arg INSTALL_POSTGRESQL=true \
	--build-arg INSTALL_SOAP=true \
	--build-arg INSTALL_LDAP=true \
	--build-arg INSTALL_PSPELL=false \
	--build-arg INSTALL_GHOSTSCRIPT=true \
	--build-arg INSTALL_GRAPHVIZ=true \
	--build-arg APP_PUBLIC_DIR=public \
	--build-arg NGINX_PROFILE=moodle \
	--build-arg PHP_MEMORY_LIMIT=512M \
	--build-arg PHP_MAX_INPUT_VARS=10000 \
	--build-arg PHP_UPLOAD_MAX_FILESIZE=512M \
	--build-arg PHP_POST_MAX_SIZE=512M \
	--build-arg NGINX_CLIENT_MAX_BODY_SIZE=512M \
	--build-arg NGINX_FASTCGI_READ_TIMEOUT=600 \
	--build-arg FPM_MAX_CHILDREN=40 \
	--build-arg FPM_START_SERVERS=8 \
	--build-arg FPM_MIN_SPARE_SERVERS=4 \
	--build-arg FPM_MAX_SPARE_SERVERS=12

# WordPress: MySQL + ImageMagick, no public subdir
WORDPRESS_ARGS = $(COMMON_ARGS) \
	--build-arg INSTALL_MYSQL=true \
	--build-arg INSTALL_IMAGEMAGICK=true \
	--build-arg APP_PUBLIC_DIR="" \
	--build-arg PHP_MEMORY_LIMIT=256M

# Symfony: MySQL/PostgreSQL + Redis
SYMFONY_ARGS = $(COMMON_ARGS) \
	--build-arg INSTALL_MYSQL=true \
	--build-arg INSTALL_POSTGRESQL=true \
	--build-arg INSTALL_REDIS=true \
	--build-arg APP_PUBLIC_DIR=public

# Mautic: MySQL + ImageMagick + Redis
MAUTIC_ARGS = $(COMMON_ARGS) \
	--build-arg INSTALL_MYSQL=true \
	--build-arg INSTALL_POSTGRESQL=true \
	--build-arg INSTALL_REDIS=true \
	--build-arg INSTALL_IMAGEMAGICK=true \
	--build-arg APP_PUBLIC_DIR="" \
	--build-arg PHP_MEMORY_LIMIT=512M

# Minimal: Just PHP-FPM + Nginx, no extras
MINIMAL_ARGS = \
	--build-arg INSTALL_COMPOSER=false \
	--build-arg INSTALL_GD=false \
	--build-arg INSTALL_INTL=false

# ─── Targets ─────────────────────────────────────────────────────────────────

.PHONY: build-laravel build-wordpress build-drupal build-moodle \
        build-symfony build-mautic build-minimal build-custom build-all \
        test clean

build-laravel:
	$(DOCKER_BUILD) $(LARAVEL_ARGS) \
		-t $(REGISTRY)/laravel-nginx-base:$(DATE_TAG) \
		-t $(REGISTRY)/laravel-nginx-base:$(LATEST_TAG) .

build-drupal:
	$(DOCKER_BUILD) $(DRUPAL_ARGS) \
		-t $(REGISTRY)/drupal-nginx-base:$(DATE_TAG) \
		-t $(REGISTRY)/drupal-nginx-base:$(LATEST_TAG) .

build-moodle:
	$(DOCKER_BUILD) $(MOODLE_ARGS) \
		-t $(REGISTRY)/moodle-nginx-base:$(DATE_TAG) \
		-t $(REGISTRY)/moodle-nginx-base:$(LATEST_TAG) .

build-wordpress:
	$(DOCKER_BUILD) $(WORDPRESS_ARGS) \
		-t $(REGISTRY)/wordpress-nginx-base:$(DATE_TAG) \
		-t $(REGISTRY)/wordpress-nginx-base:$(LATEST_TAG) .

build-symfony:
	$(DOCKER_BUILD) $(SYMFONY_ARGS) \
		-t $(REGISTRY)/symfony-nginx-base:$(DATE_TAG) \
		-t $(REGISTRY)/symfony-nginx-base:$(LATEST_TAG) .

build-mautic:
	$(DOCKER_BUILD) $(MAUTIC_ARGS) \
		-t $(REGISTRY)/mautic-nginx-base:$(DATE_TAG) \
		-t $(REGISTRY)/mautic-nginx-base:$(LATEST_TAG) .

build-minimal:
	$(DOCKER_BUILD) $(MINIMAL_ARGS) \
		-t $(REGISTRY)/php-nginx-base:$(DATE_TAG)-minimal \
		-t $(REGISTRY)/php-nginx-base:$(LATEST_TAG)-minimal .

build-custom:
	$(DOCKER_BUILD) $(COMMON_ARGS) $(ARGS) \
		-t $(REGISTRY)/$(IMAGE_NAME):$(DATE_TAG)-custom \
		-t $(REGISTRY)/$(IMAGE_NAME):$(LATEST_TAG)-custom .

build-all: build-laravel build-drupal build-moodle build-wordpress build-symfony build-mautic build-minimal

# Quick smoke test
test:
	@echo "── Testing $(REGISTRY)/laravel-nginx-base:$(LATEST_TAG) ──"
	docker run --rm -d --name php-base-test \
		$(REGISTRY)/laravel-nginx-base:$(LATEST_TAG)
	sleep 5
	docker exec php-base-test curl -sf http://127.0.0.1:8080/healthz
	docker exec php-base-test php -v
	docker exec php-base-test php -m
	docker exec php-base-test nginx -t
	docker stop php-base-test
	@echo "✓ Tests passed"

clean:
	docker images --filter=reference="$(REGISTRY)/$(IMAGE_NAME)" -q \
		| xargs -r docker rmi -f
