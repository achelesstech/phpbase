# =============================================================================
# Makefile — achelesstech/php-base
# =============================================================================
# There is ONE image. It has no platform variants and no feature toggles.
# The only axis is the PHP version.
#
#   make build            build 8.4 (default)
#   make build PHP=8.2    build 8.2
#   make build-all        build every supported version
#   make test             boot the image and assert it actually works
#   make shell            interactive shell in the built image
# =============================================================================

REGISTRY    ?= ghcr.io/achelesstech
IMAGE       ?= php-base
PHP         ?= 8.4
ALPINE      ?= 3.21
PHP_ALL     ?= 8.2 8.4

VERSION     ?= $(shell date '+%Y%m%d-%H%M')
TAG         := $(REGISTRY)/$(IMAGE):$(PHP)
TAG_PINNED  := $(REGISTRY)/$(IMAGE):$(PHP)-$(VERSION)
CACHE_REF   := $(REGISTRY)/$(IMAGE):$(PHP)-buildcache

BUILD_ARGS = \
	--build-arg PHP_VERSION=$(PHP) \
	--build-arg ALPINE_VERSION=$(ALPINE) \
	--build-arg BASE_VERSION=$(PHP)-$(VERSION)

.PHONY: build build-all test shell lint scan push clean

build:
	docker buildx build \
		$(BUILD_ARGS) \
		--cache-from type=registry,ref=$(CACHE_REF) \
		-t $(TAG) -t $(TAG_PINNED) \
		--load .

build-all:
	@for v in $(PHP_ALL); do $(MAKE) --no-print-directory build PHP=$$v || exit 1; done

# Push with registry-side layer caching so app repos and CI never recompile
# extensions. mode=max caches intermediate stages too.
push:
	docker buildx build \
		$(BUILD_ARGS) \
		--cache-from type=registry,ref=$(CACHE_REF) \
		--cache-to   type=registry,ref=$(CACHE_REF),mode=max \
		--platform linux/amd64,linux/arm64 \
		-t $(TAG) -t $(TAG_PINNED) \
		--push .

lint:
	docker run --rm -i hadolint/hadolint < Dockerfile

scan:
	trivy image --severity HIGH,CRITICAL --ignore-unfixed $(TAG)

# =============================================================================
# Smoke test
# =============================================================================
# Builds a minimal fixture application on the base, boots it, and asserts real
# behaviour. See test/run.sh — every check maps to something that was actually
# broken in the previous revision.
# =============================================================================
test: build
	@./test/run.sh $(TAG)

shell: build
	docker run --rm -it --entrypoint sh $(TAG)

clean:
	-docker rm -f php-base-test 2>/dev/null
	-docker images --filter=reference="$(REGISTRY)/$(IMAGE)" -q | xargs -r docker rmi -f
