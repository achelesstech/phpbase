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

.PHONY: build build-all test test-frameworks resolve lint scan shell clean

# Pinned inputs from the resolver (cached per day; REFRESH=1 re-resolves).
# Resolved once, so runtime and dev get the identical argument list.
build:
	@args="$$(./scripts/build-args.sh $(PHP))" || exit 1; \
	set -x; \
	docker buildx build $$args --target runtime -t $(TAG) --load . && \
	docker buildx build $$args --target dev -t $(DEV_TAG) --load .

build-all:
	@for v in $(PHP_ALL); do $(MAKE) --no-print-directory build PHP=$$v || exit 1; done

test: build
	./test/run.sh $(TAG) $(PHP)
	./test/run-dev.sh $(DEV_TAG)

# Every version each framework lists for $(PHP) in versions.json, one run each.
test-frameworks: build
	@fw="$$(jq -ce --arg l '$(PHP)' '.php[] | select(.line == $$l) | .frameworks' versions.json)" \
		|| { echo "PHP $(PHP) is not a line in versions.json" >&2; exit 1; }; \
	set -x; ./test/frameworks/run.sh '$(TAG)' "$$fw"

resolve:
	./scripts/resolve-matrix.sh | sed -n 's/^lines=//p' | jq '.[] | {line, php_version, alpine_full, alpine_image, build_tag, tags}'

# Same configs CI uses.
lint:
	docker run --rm -i -v "$(CURDIR)/.hadolint.yaml:/.hadolint.yaml:ro" \
		hadolint/hadolint hadolint --config /.hadolint.yaml - < Dockerfile
	docker run --rm -v "$(CURDIR):/src:ro" -w /src koalaman/shellcheck:v0.11.0 -S warning -x -s sh \
		rootfs/usr/local/bin/docker-entrypoint.sh rootfs/usr/local/bin/healthcheck.sh \
		rootfs/usr/local/bin/php-base-every rootfs/usr/local/bin/php-base-info \
		rootfs/usr/local/bin/php-base-validate rootfs/usr/local/bin/nginx-validate.sh \
		rootfs/usr/local/bin/php-base-web rootfs/etc/php-base/s6/.s6-svscan/SIGTERM \
		rootfs/etc/php-base/s6/.s6-svscan/finish rootfs/etc/php-base/s6/fail-fast rootfs/etc/php-base/s6/*/run
	docker run --rm -v "$(CURDIR):/src:ro" -w /src koalaman/shellcheck:v0.11.0 -S warning -x -s bash \
		scripts/*.sh scripts/lib/*.sh test/*.sh test/runtime/*.sh test/scripts/*.sh test/frameworks/*.sh

scan:
	trivy image --severity HIGH,CRITICAL --ignore-unfixed $(TAG)

shell:
	docker run --rm -it --entrypoint sh $(TAG)

clean:
	-docker images --filter=reference='$(IMAGE)' -q | xargs -r docker rmi -f
