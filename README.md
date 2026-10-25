# achelesstech/php-base

A PHP base image: **PHP-FPM and nginx on Alpine, supervised by s6**, non-root,
built to sit behind a TLS-terminating reverse proxy (Traefik, optionally with
Cloudflare in front). One image serves Laravel 12/13, Drupal 11, WordPress and
Moodle 5.1–5.3.

```
Traefik (TLS) ──► :8080 ┌──────────────────────────────────────────────────┐
                        │ nginx ──unix socket──► php-fpm        (s6)        │
                        │ server{} from a preset or the app image            │
                        │ status pages on 127.0.0.1:8081 only                │
                        │ tini PID 1 · every process www-data 1000:1000      │
                        │ writes only under /tmp                             │
                        └──────────────────────────────────────────────────┘
```

Published as `docker.io/achelesstech/php-base`. CI rebuilds it from the newest
PHP patch release and the newest Alpine packages, tests every build under the
production run flags and against real installs of all four frameworks, and
publishes only the digest it tested.

## The one rule

**This image is deliberately boring.** It has no platform identity and no
feature toggles: there is no `php-base:laravel`, no `INSTALL_LDAP`. Every
application gets the same fixed set of extensions, and the differences live
where they belong:

| | Where it lives | Why |
|---|---|---|
| Compiled PHP extensions | **base** (the union all four frameworks need) | Compiling needs a toolchain and is slow; shared by every app on the host |
| OS packages (`ghostscript`, DB clients, `nodejs`) | **app image** | `apk add` takes seconds and needs no compiler; keeps them next to the app that needs them |
| nginx `http{}` block | **base** | Genuinely common |
| nginx `server{}` block | **app image**: a preset symlink or its own vhost | Every app routes differently |
| Numbers (memory, pool size, timeouts) | **runtime env** | They change per deployment, not per build |

## Tags

| Tag | What it is |
|---|---|
| `achelesstech/php-base:8.4` | the newest build of the 8.4 line. Moves with every rebuild: **pin it by digest** |
| `achelesstech/php-base:8.4.27` | the newest build of PHP 8.4.27. Moves when Alpine packages are rebuilt |
| `achelesstech/php-base:8.4.27-20261026` | one build. Never moves. A second build on the same day gets `…-20261026.2` |
| `achelesstech/php-base:8.4-dev` | the `-dev` twin of `:8.4`; every tag above has one (`:8.4.27-dev`, …) |
| `achelesstech/php-base:latest` | the newest stable line (8.5); `:latest-dev` is its twin. Not for production |
| `achelesstech/php-base:8.6-rc` | the pre-release canary, published only when it builds and passes; `:8.6-rc-dev` |

Stable lines are 8.2, 8.3, 8.4 and 8.5. **PHP 8.2's security support ends
2026-12-31**; CI stops building it after that date. There are no
`8.4-alpine3.24`-style tags any more: a tag pinned to one Alpine release stops
receiving PHP updates when upstream moves on, which is how v1 sat on an old
PHP for eleven months.

The runtime image is for production. The `-dev` image adds Composer, git,
unzip, patch, openssh-client, Xdebug and PCOV (both off), PHP sources,
headers, `phpize` and the `docker-php-ext-*` helpers. Use it for local
development and as the `composer install` build stage.

Images are signed with cosign (keyless) and carry an SBOM and provenance.
[`docs/docker-hub.md`](docs/docker-hub.md) shows `cosign verify`.

## Quick start

```dockerfile
# Pin by digest; a moving tag makes last week's build unreproducible.
#   docker buildx imagetools inspect docker.io/achelesstech/php-base:8.4
FROM docker.io/achelesstech/php-base:8.4@sha256:<runtime digest>

USER root
# Code stays root-owned (COPY's default): a compromised PHP process cannot
# rewrite it.
COPY . /var/www/html
# The framework's preset; pick yours from /etc/nginx/presets/.
RUN ln -s /etc/nginx/presets/laravel.conf /etc/nginx/conf.d/default.conf \
 && php-base-validate
USER www-data
```

This is the part every framework shares. Under `--read-only`, every path the
app writes at runtime (caches, logs, uploads, sessions) needs a volume or a
tmpfs; owning it as `www-data` in the image is not enough. Dependencies are
installed in a `-dev` build stage, because Composer is only in `-dev`. The
app templates in [`examples/laravel/`](examples/laravel/),
[`examples/drupal/`](examples/drupal/),
[`examples/wordpress/`](examples/wordpress/) and
[`examples/moodle/`](examples/moodle/) are complete, tested patterns for both.

Run it the way production does (these are the flags the test suite uses):

```sh
docker run --rm -p 8080:8080 \
  --read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,size=256m --cap-drop ALL \
  --security-opt no-new-privileges --pids-limit 256 --memory 1g \
  my-app
```

The same image runs the queue worker and the scheduler with a different
command:

```yaml
queue:     { command: [php, artisan, queue:work, --max-time=3600] }
scheduler: { command: [php-base-every, "60", php, artisan, schedule:run] }
```

### What the application image must provide

1. **One `server{}` block listening on 8080** in `/etc/nginx/conf.d/`: a
   symlink to a preset in `/etc/nginx/presets/` (`laravel.conf`,
   `drupal.conf`, `wordpress.conf`, `moodle.conf`, `moodle-legacy.conf`), or
   its own vhost.
2. **`RUN php-base-validate`** after it (`nginx-validate.sh` is the same
   command), so a broken config fails the build rather than production.

Nothing else. The health and status pages (`/fpm-ping`, `/fpm-status`,
`/nginx-status`) are part of the image, on `127.0.0.1:8081`, so a vhost does
not define them.

Working app templates for Laravel, Drupal, WordPress and Moodle are in
[`examples/`](examples/). Copy an app template into the application
repository.

**Behind Traefik and Cloudflare?** Read
[`docs/reverse-proxy.md`](docs/reverse-proxy.md) before going live. A
hardened Traefik deployment is in [`examples/traefik/`](examples/traefik/),
and Portainer behind it in [`examples/portainer/`](examples/portainer/).

## Documentation

| Document | What it covers |
|---|---|
| [`docs/image.md`](docs/image.md) | contents, the runtime contract, roles, every environment variable, presets, tuning |
| [`docs/security.md`](docs/security.md) | threat model, the hardened run flags, what the tests prove, the ImageMagick policy |
| [`docs/reverse-proxy.md`](docs/reverse-proxy.md) | Traefik and Cloudflare: client IPs, keep-alive, compression, timeouts |
| [`docs/README.md`](docs/README.md) | every other document |

## Development

```bash
make build              # PHP 8.4, runtime and dev  ->  local/php-base:8.4[-dev]
make build PHP=8.5
make build-all          # every line in versions.json
make test               # the runtime suite (hardened flags) and the dev suite
make test-frameworks    # real Laravel, Drupal, WordPress and Moodle installs
make resolve            # what CI would build right now: digests and tags
make lint               # hadolint and shellcheck
make scan               # Trivy, HIGH/CRITICAL
make shell
```

Local builds are named `local/php-base:*` on purpose. Building as
`docker.io/achelesstech/php-base:8.4` would silently replace the image every
app on this machine builds from.

## Layout

```
Dockerfile                    multi-stage: ext-builder, runtime (clean Alpine), dev
rootfs/                       files for the runtime image
  etc/nginx/                  nginx.conf (http{} only), presets/, php-base/ snippets
  etc/php-base/s6/            service definitions: php-fpm, nginx, scheduler, worker
  etc/ImageMagick-7/          policy.xml: format allowlist and resource caps
  usr/local/bin/              entrypoint, healthcheck, php-base-web, php-base-every, …
  usr/local/etc/              zz-base.ini, php-fpm.d/www.conf
rootfs-dev/                   additions for the -dev image
versions.json                 build matrix: lines, EOL, latest, size ceilings, frameworks
scripts/                      resolver, guards, link checker, Cloudflare ranges
test/                         runtime and dev suites, framework smoke tests, script tests
examples/                     app templates to copy into app repositories
examples/traefik/             the edge proxy
examples/portainer/           Portainer CE behind Traefik
docs/                         image reference, security, reverse proxy, Docker Hub text
docs/traefik/                 the edge proxy's labels, static config, VPS setup
docs/portainer/               why the Portainer install differs from the official one
.github/workflows/            build-base.yml, watch-upstream.yml
```

Every config file is a real file under `rootfs/`. None is generated by
`RUN cat <<EOF` heredocs: that is how an earlier revision shipped Dockerfiles
that could not build and PHP that would not parse.
