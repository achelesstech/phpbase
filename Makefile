# =============================================================================
# Makefile — achelesstech/php-base
# =============================================================================
# One image per PHP line, two variants (runtime, dev). CI is the publisher;
# these targets reproduce what it does, locally.
#
#   make build                    8.4 runtime + dev  ->  local/php-base:8.4[-dev]
#   make build PHP=8.5
#   make build-all                every line in versions.json
#   make test                     behaviour tests (runtime + dev)
#   make test-frameworks          Laravel/Drupal/WordPress/Moodle smoke tests
#   make resolve                  what CI would build right now (digests, tags)
#   make lint | scan | shell
#
# Local tags are local/php-base:* ON PURPOSE: building as
# docker.io/achelesstech/php-base:8.4 would silently replace the image every
# app on this machine builds FROM.
# =============================================================================

PHP        ?= 8.4
IMAGE      ?= local/php-base
PHP_ALL    ?= $(shell jq -r '.php[] | select((.prerelease // false) | not) | .line' versions.json)
TAG        := $(IMAGE):$(PHP)
DEV_TAG    := $(IMAGE):$(PHP)-dev
UPSTREAM   := $(if $(filter 8.6,$(PHP)),php:$(PHP)-rc-fpm-alpine,php:$(PHP)-fpm-alpine)

BUILD_ARGS = \
	--build-arg PHP_VERSION=$(PHP) \
	--build-arg PHP_IMAGE=$(UPSTREAM) \
	--build-arg BASE_NAME=docker.io/library/$(UPSTREAM) \
	--build-arg BASE_VERSION=$(PHP)-local \
	--build-arg BUILD_DATE=$(shell date -u +%Y-%m-%dT%H:%M:%SZ) \
	--build-arg VCS_REF=$(shell git rev-parse --short HEAD 2>/dev/null || echo unknown) \
	--build-arg PKG_CACHE_BUST=$(shell date -u +%Y%m%d)

.PHONY: build build-all test test-frameworks resolve lint scan shell clean

build:
	docker buildx build $(BUILD_ARGS) --target runtime -t $(TAG) --load .
	docker buildx build $(BUILD_ARGS) --target dev -t $(DEV_TAG) --load .

build-all:
	@for v in $(PHP_ALL); do $(MAKE) --no-print-directory build PHP=$$v || exit 1; done

test: build
	./test/run.sh $(TAG) $(PHP)
	./test/run-dev.sh $(DEV_TAG)

test-frameworks: build
	./test/frameworks/run.sh $(TAG) '$(shell jq -c --arg l $(PHP) '.php[] | select(.line == $$l) | .frameworks' versions.json)'

resolve:
	./scripts/resolve-matrix.sh | sed -n 's/^lines=//p' | jq '.[] | {line, php_version, alpine_full, tags}'

# Same configs CI uses.
lint:
	docker run --rm -i -v "$(CURDIR)/.hadolint.yaml:/.hadolint.yaml:ro" \
		hadolint/hadolint hadolint --config /.hadolint.yaml - < Dockerfile
	docker run --rm -v "$(CURDIR):/src:ro" -w /src koalaman/shellcheck:v0.11.0 -S warning -x -s sh \
		rootfs/usr/local/bin/docker-entrypoint.sh rootfs/usr/local/bin/healthcheck.sh \
		rootfs/usr/local/bin/php-base-every rootfs/usr/local/bin/php-base-info \
		rootfs/usr/local/bin/php-base-validate rootfs/usr/local/bin/nginx-validate.sh
	docker run --rm -v "$(CURDIR):/src:ro" -w /src koalaman/shellcheck:v0.11.0 -S warning -x -s bash \
		scripts/*.sh test/*.sh test/frameworks/*.sh

scan:
	trivy image --severity HIGH,CRITICAL --ignore-unfixed $(TAG)

shell:
	docker run --rm -it --entrypoint sh $(TAG)

clean:
	-docker images --filter=reference='$(IMAGE)' -q | xargs -r docker rmi -f
