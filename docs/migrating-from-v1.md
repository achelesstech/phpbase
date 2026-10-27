# Migrating from v1

What breaks when an app image moves from php-base v1 (supervisord, PHP-FPM on
TCP 9000) to v2, and what to change. Work through
[Breaking changes](#breaking-changes) first: each one stops the build or the
container. [Behaviour changes](#behaviour-changes) won't stop anything, but
they change what you see in production.

The full reference for v2 is [`image.md`](image.md); the run flags and the
threat model are in [`security.md`](security.md). The
[app templates](../examples/) show the finished pattern for Laravel, Drupal,
WordPress and Moodle.

- [Before you start](#before-you-start)
- [Breaking changes](#breaking-changes)
- [Behaviour changes](#behaviour-changes)
- [Not breaking, but do it now](#not-breaking-but-do-it-now)
- [FarmBook and HQ](#farmbook-and-hq)
- [Checklist](#checklist)

## Before you start

- **Image and tags.** v2 is `docker.io/achelesstech/php-base`. The tag scheme
  is in the [README](../README.md#tags); v1's `X.Y-<run number>` tags are not
  continued. Pin by digest: `:8.4` moves with every rebuild.
- **Two base images.** The runtime `X.Y` is for production. The `X.Y-dev` twin
  adds Composer and the build tools. Most app Dockerfiles now start from both:
  a `-dev` build stage, then a runtime production stage.
- **Docker Engine 25 or newer**, for `HEALTHCHECK --start-interval` (see
  [`image.md`](image.md#healthcheck)). Older engines ignore it and probe every
  30 s from the start.
- **Unchanged:** user `www-data` 1000:1000, port 8080, `/var/www/html`, the
  `/docker-entrypoint.d/*.sh` hooks, `nginx-validate.sh`, and the names of the
  `PHP_*`, `FPM_*` and `HEALTHCHECK_*` variables v1 had.

## Breaking changes

### 1. supervisord is gone; the default CMD is `php-base-web`

v1 ran `supervisord -c /etc/supervisor/supervisord.conf`. v2 runs
`php-base-web`, which supervises nginx and PHP-FPM with s6. Python, which
supervisord needed, is gone too.

**What breaks.** An image or compose file that still runs `supervisord`
exits at start with:

```
supervisord was removed in php-base v2: use the default CMD (php-base-web), SCHEDULER_COMMAND/WORKER_COMMAND, or a separate container — see docs/migrating-from-v1.md
```

`/etc/supervisor` no longer exists. A `COPY` of your own program files into
`/etc/supervisor/conf.d/` still builds, but nothing reads them.

**What to do.**
- Delete any `CMD ["supervisord", …]` from the Dockerfile and any
  `command: supervisord …` from compose. The image's default CMD is right
  for the web container.
- Delete files you copied into `/etc/supervisor/`.
- Move each extra supervisord program you ran next to nginx:
  - **Recommended:** a separate container from the same image with its own
    `command:`, e.g.
    `queue: { command: [php, artisan, queue:work, --max-time=3600] }` and
    `scheduler: { command: [php-base-every, "60", php, artisan, schedule:run] }`.
    It restarts, scales and logs on its own, and a crash in it can't take the
    site down.
  - **Small sites:** keep it in the web container with `WORKER_COMMAND` (a
    long-running process, restarted when it exits) or `SCHEDULER_COMMAND`
    (run every `SCHEDULER_INTERVAL` seconds). See
    [`image.md`](image.md#roles-one-image-any-command).
- A cron loop such as `while true; do …; sleep 60; done` becomes
  `php-base-every 60 …`. It runs on the minute without drifting, never
  overlaps runs, and gives the healthcheck a heartbeat.

### 2. PHP-FPM listens on a Unix socket, not TCP 9000

PHP-FPM listens on `/tmp/php-base/php-fpm.sock` only; the TCP listener is
gone. v1's was already loopback-only (`listen = 127.0.0.1:9000`,
`listen.allowed_clients = 127.0.0.1`), so this doesn't close an open port.
It removes the port altogether: with no FastCGI port, none can be
misconfigured or published. That matters because a FastCGI client can set
`PHP_VALUE` and run any code.

**What breaks.** A vhost with `fastcgi_pass 127.0.0.1:9000;` still passes
`nginx -t`, but every PHP request returns 502. Unless `HEALTHCHECK_URL` points at a
PHP page, the healthcheck stays green, because the status listener uses the
socket.

**What to do.** Use a preset if one fits (`laravel.conf`, `drupal.conf`,
`wordpress.conf`, `moodle.conf`, `moodle-legacy.conf`;
[`image.md`](image.md#nginx-presets-and-your-own-vhost)). If you keep your
own vhost, end its PHP location with the base's handler:

```nginx
location ~ \.php$ {
    include /etc/nginx/php-base/fastcgi-php.conf;   # includes fastcgi_pass php_fpm
}
```

or, if you write the handler yourself, use `fastcgi_pass php_fpm;`. That is
the upstream in the base `nginx.conf` that points at the socket. Then
`RUN php-base-validate` so a mistake fails the build, not production.

### 3. Status pages are on 127.0.0.1:8081

`/fpm-ping`, `/fpm-status` and `/nginx-status` are served by the base on an
internal listener, `127.0.0.1:8081`, in every app. The v1 approach (an
`allow 127.0.0.1` ACL on port 8080) could be bypassed: nginx trusts
`X-Forwarded-For` from the private ranges, so any container on the network
could send `X-Forwarded-For: 127.0.0.1`.

**What breaks.**
- v1 vhosts defined their own `location = /fpm-ping` (and status) blocks
  with `fastcgi_pass 127.0.0.1:9000`. They still pass `nginx -t`, but they
  point at the old TCP address and re-open the ACL bypass.
- `HEALTHCHECK_PORT=8080` points the healthcheck at the public port, where
  `/fpm-ping` no longer exists, so the container never becomes healthy.
- A monitoring sidecar that scraped `/fpm-status` over the network can't reach
  8081.

**What to do.** Delete the status `location` blocks and any
`HEALTHCHECK_PORT`/`HEALTHCHECK_PATH` override. Read status from inside the
container:

```sh
docker compose exec app curl -s '127.0.0.1:8081/fpm-status?full'
```

### 4. Composer and the build tools are only in `-dev`

The runtime image has no Composer, git, Info-ZIP unzip (busybox's `unzip`
is there), patch, openssh-client, PHP
sources, headers, `phpize`, PEAR/PECL or `docker-php-ext-*` helpers.

**What breaks.** `RUN composer install`, `pecl install`,
`docker-php-ext-install` or `docker-php-source` in a stage `FROM` the
runtime image fails with "not found".

**What to do.** Run Composer in a build stage `FROM php-base:X.Y-dev` and
copy `vendor/` into the production stage `FROM php-base:X.Y`:

```dockerfile
ARG PHP_BASE_IMAGE=docker.io/achelesstech/php-base:8.4@sha256:<runtime>
ARG PHP_BASE_DEV_IMAGE=docker.io/achelesstech/php-base:8.4-dev@sha256:<dev>

FROM ${PHP_BASE_DEV_IMAGE} AS vendor
WORKDIR /var/www/html
COPY --chown=www-data:www-data composer.json composer.lock ./
RUN composer install --no-dev --no-interaction --prefer-dist --no-scripts --no-autoloader

# … a stage that adds the source and runs `composer dump-autoload` …

FROM ${PHP_BASE_IMAGE} AS production
# Root-owned code: a compromised PHP process can't rewrite it.
COPY --from=build --chown=root:root /var/www/html /var/www/html
```

[`examples/laravel/Dockerfile`](../examples/laravel/Dockerfile) is the full
version. The local-development target should also start from `-dev`. It
already has Xdebug and PCOV (both off until `XDEBUG_MODE` or
`pcov.enabled=1`), so delete any step that built Xdebug.

Extensions the base doesn't ship can be compiled only in `-dev`
(`apk add $PHPIZE_DEPS && docker-php-ext-install …`, as root).

### 5. No `php.ini-production` or `php.ini-development`

The runtime image is a clean Alpine with only PHP's runtime files copied in.
`/usr/local/etc/php/` holds only `conf.d/`, in `-dev` as well.

**What breaks.** The official image's idiom

```dockerfile
RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"
```

fails the build: `mv: can't rename '/usr/local/etc/php/php.ini-production': No such file or directory`.

**What to do.** Delete the line. The base's `conf.d/zz-base.ini` already sets
the production values that matter (`expose_php=Off`, errors logged, not
shown, `zend.exception_ignore_args=On`, …). `-dev` adds `zz-dev.ini` for
development. Change a setting with its `PHP_*` variable or `PHP_INI_EXTRA`
([`image.md`](image.md#php)), or a root-owned `.ini` in
`$PHP_INI_DIR/conf.d/`.

### 6. `HOME` is a link into `/tmp`

`/home/www-data` is a symlink to `/tmp/php-base/home`. The entrypoint
recreates that directory, empty, at every start. The root filesystem is meant
to be read-only, so a real home directory could never be written.

**What breaks.**
- Anything kept in `~` is lost at every restart.
- In a `docker build` stage, `$HOME` points at nothing (no entrypoint has
  run), so a build step that writes to `~` fails. Examples: `npm` without a
  cache setting, `git config --global`, Composer without `COMPOSER_HOME`.

**What to do.** At runtime, `~` is writable, so workarounds such as
`npm_config_cache=/tmp/.npm` are no longer needed. In build stages, point
tools at `/tmp` (`-dev` already sets `COMPOSER_HOME=/tmp/composer`), or run
Node in its own stage, as the Laravel template does.

### 7. Runtime paths moved under `/tmp/php-base`

`/etc/php-runtime.d/` and `/usr/local/etc/php-fpm.d/zz-runtime.conf` are
gone. The entrypoint renders everything into `/tmp/php-base/` and wipes it at
every start ([`image.md`](image.md#the-runtime-contract)). The release file
moved from `/etc/php-base-release` to `/etc/php-base/release`; use
`php-base-info`.

**What to do.** If a hook writes to one of the old paths, set the matching
env variable instead (`PHP_INI_EXTRA`, `FPM_POOL_EXTRA`).

## Behaviour changes

Nothing here stops a container, but what you see changes.

| | v1 | v2 | To get v1 back |
|---|---|---|---|
| nginx access log | on, `main` format, stdout | off: Traefik already logs every request | `NGINX_ACCESS_LOG=main` (or `json`) |
| PHP-FPM access log | on, stdout | off | `FPM_ACCESS_LOG=1` |
| Dynamic gzip | on | off: Traefik compresses; `gzip_static` still serves `.gz` files | `NGINX_GZIP=1`, only without a compressing proxy in front |
| nginx `keepalive_timeout` | 65 s | 120 s, longer than Traefik's 90 s ([`reverse-proxy.md`](reverse-proxy.md#keep-alive-nginx-120s-traefik-90s)) | — |
| `client_max_body_size` | fixed `100m` | follows PHP's `post_max_size` (64M by default) | `NGINX_CLIENT_MAX_BODY_SIZE`, or raise `PHP_POST_MAX_SIZE` |
| PHP-FPM workers | fixed 12 | `FPM_MAX_CHILDREN=auto`, sized from the memory limit: 7 with `--memory 1g` and a 256 MB `/tmp` tmpfs, 12 with no limit ([`image.md`](image.md#php-fpm-workers-fpm_max_childrenauto)) | `FPM_MAX_CHILDREN=12` |
| Client IP behind Cloudflare | Cloudflare's edge address | the visitor's address (Cloudflare's ranges are trusted) | `NGINX_TRUST_CLOUDFLARE=0` |
| Healthcheck | `/fpm-ping` on 8080, web only | role-aware, see below | — |

### Healthchecks: drop the `pgrep` overrides

v1's healthcheck only worked in the web container, so worker and scheduler
services carried overrides such as

```yaml
healthcheck:
  test: ["CMD-SHELL", "pgrep -f 'queue:work' >/dev/null || exit 1"]
```

Delete them. A `pgrep` check only shows that a process exists, not that it
works. The image's check now picks its probe by role:

| Container | Probe |
|---|---|
| web (`php-base-web`) | `/fpm-ping` on `127.0.0.1:8081` through FastCGI, plus `HEALTHCHECK_URL` if set (e.g. Laravel's `http://127.0.0.1:8080/up`) |
| `php-base-every …` | the heartbeat: the last successful run is recent |
| any other command (a queue worker) | none |

Details and the other modes are in [`image.md`](image.md#healthcheck). Don't
replace the web check with something slower: Traefik routes only to healthy
containers, so a slow check delays every deploy
([`traefik/labels.md`](traefik/labels.md#health-traefik-routes-only-to-healthy-containers)).

## Not breaking, but do it now

**Copy hooks root-owned.** Hooks run at every start, so one that `www-data`
can modify lets a compromised PHP process run code at the next start. A
hook copied with `COPY --chown=www-data …`, or writable by group or others,
logs a warning at every start. Copy it without `--chown` (mode 0755 or
0644). Once no warning is left, set `PHP_BASE_STRICT=1`, so a bad hook stops
the container instead.

**Run with the hardened flags** (read-only root, a sized `/tmp` tmpfs, all
capabilities dropped): [`security.md`](security.md#the-hardened-run-flags).
v2 writes only under `/tmp`, so `read_only: true` works.

## FarmBook and HQ

The two Laravel apps on v1, and what each needs. The apps live in their own
repositories. [`examples/laravel/`](../examples/laravel/) is the target
pattern.

| Today | With v2 |
|---|---|
| `FROM …php-base:8.4`, built locally, PHP 8.4.15 | `FROM docker.io/achelesstech/php-base:8.4@sha256:…` for production and `…:8.4-dev@sha256:…` for the Composer stage, from Docker Hub. Renovate keeps both digests current (the template's `renovate.json`) |
| `CMD`/`command:` with supervisord, if overridden | delete it ([1](#1-supervisord-is-gone-the-default-cmd-is-php-base-web)) |
| `composer install` in a runtime stage, if present | a `-dev` build stage ([4](#4-composer-and-the-build-tools-are-only-in--dev)) |
| Xdebug built from GitHub source in the dev stage | `FROM php-base:8.4-dev`: Xdebug is there, off until `XDEBUG_MODE` is set |
| `npm_config_cache=/tmp/.npm` workaround | delete it for runtime: `$HOME` is writable there. In a build stage on php-base `$HOME` doesn't exist, so run npm in its own Node stage ([6](#6-home-is-a-link-into-tmp)) |
| FarmBook's hand-fixed vhost; HQ's permissive one | a symlink to the `laravel.conf` preset. For HQ this also means only `public/index.php` executes |
| `/fpm-ping` and status locations in the vhost, if present | delete them ([3](#3-status-pages-are-on-1270018081)) |
| `fastcgi_pass 127.0.0.1:9000` in an own vhost, if present | the preset, or `fastcgi_pass php_fpm` ([2](#2-php-fpm-listens-on-a-unix-socket-not-tcp-9000)) |
| `client_max_body_size` set apart from PHP | delete it: nginx follows `PHP_POST_MAX_SIZE` |
| `postgresql17-client` | `postgresql18-client`, to match the PostgreSQL 18 server (Alpine 3.24 has both) |
| worker and scheduler `healthcheck:` overrides with `pgrep` | delete them; run the scheduler as `php-base-every 60 php artisan schedule:run` and set `HEALTHCHECK_URL=http://127.0.0.1:8080/up` on the app |
| hooks copied with `--chown=www-data` | copy them root-owned (until then, a warning at every start) |
| Cloudflare visitor IP lost behind Traefik | fixed in the base; nothing to do |
| FPM and nginx access logs on stdout | off by default; `FPM_ACCESS_LOG=1`, `NGINX_ACCESS_LOG=main` bring them back |
| hooks that write to `/etc/php-runtime.d` or `php-fpm.d/zz-runtime.conf` | neither app does, but check: those paths are gone ([7](#7-runtime-paths-moved-under-tmpphp-base)) |

Then deploy behind Traefik with the template's `compose.prod.yml`: read-only,
a 256 MB `/tmp` tmpfs, `mem_limit: 1g` for `app` (7 PHP-FPM workers) and
512m for `queue` and `scheduler`, and `TRAEFIK_CERT_RESOLVER` set by where
the domain's DNS is hosted ([`reverse-proxy.md`](reverse-proxy.md#certificates-which-resolver)).

## Checklist

```sh
# No v1 leftovers in the app repository:
grep -rnE 'supervisor|:9000|fpm-ping|pgrep|php\.ini-(production|development)|php-runtime\.d' \
  Dockerfile compose*.yml docker/
# Hooks root-owned:
docker run --rm --entrypoint ls my-app -l /docker-entrypoint.d/
```

Then build, start the stack and check:
- `docker compose ps` shows `app` **healthy** within seconds, the scheduler
  healthy (and staying so while its runs succeed), and the worker healthy (its check is `none`,
  which always passes);
- `docker compose logs app` has no `is not root-owned` or `writable by group`
  warnings;
- the `fpm: max_children=…` line in the log matches the memory you meant to
  give it.
