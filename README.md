# achelesstech/php-base

One PHP runtime image. **PHP-FPM + Nginx + Supervisor**, non-root, designed to
sit behind a TLS-terminating reverse proxy (Traefik).

```
Traefik (TLS) ──► :8080 ┌─────────────────────────────────────────┐
                        │ nginx ──► php-fpm    supervisor          │
                        │ vhost supplied by the APPLICATION image  │
                        │ hooks: /docker-entrypoint.d/*.sh         │
                        │ tini PID 1 · www-data 1000:1000          │
                        └─────────────────────────────────────────┘
```

## The one rule

**This image is deliberately boring.** It has no platform identity and no
feature toggles. There is no `php-base:laravel`, no `INSTALL_LDAP`, no
`NGINX_PROFILE`. Every application gets the same fixed payload.

That is the whole design. The previous revision was one Dockerfile with 42
build args producing seven differently-named "base" images; the configurability
*was* the complexity, and it hid real bugs (a build arg that had never done
anything, a uid/gid that was silently wrong).

| | Where it lives | Why |
|---|---|---|
| Compiled PHP extensions | **base** (union of all apps) | Slow: needs `$PHPIZE_DEPS` and a compiler. ~40MB more than a minimal set, shared by every app on the host. |
| OS packages (`ghostscript`, `graphviz`, DB clients) | **app image** | `apk add` takes seconds and needs no compiler. Keeps them attached to the app that needs them. |
| nginx `http{}` block | **base** | Genuinely common. |
| nginx `server{}` block | **app image** | Every app's routing is different, and it belongs next to the code it serves. |
| Numbers (memory, pool size, timeouts) | **runtime env** | These change per deployment, not per build. |

## Using it

```dockerfile
# Pin by digest. A moving tag means your app image changes silently
# and last week's build is not reproducible.
FROM docker.io/achelesstech/php-base:8.4@sha256:...

COPY docker/vhost.conf    /etc/nginx/conf.d/vhost.conf
COPY docker/entrypoint.d/ /docker-entrypoint.d/
COPY --chown=www-data:www-data . /var/www/html

RUN nginx-validate.sh   # fail the build, not production
```

Use `nginx-validate.sh`, **not** a bare `nginx -t`. `nginx -t` creates the pid
file and opens its compiled-in default error log as a side effect; when the
build step runs as root that bakes root-owned files into the image and nginx
then cannot start as www-data at runtime. The wrapper cleans up after itself.

Working templates for Laravel 11/13, Drupal 11, Moodle 5.0/5.2 and WordPress
are in [`apps/`](apps/). Copy one into the application repository.

**Behind Traefik and Cloudflare?** Read
[`docs/reverse-proxy.md`](docs/reverse-proxy.md) before going live. A complete,
hardened Traefik deployment — static config, dynamic config, compose, and a
labels reference for app repos — is in [`traefik/`](traefik/). It lives here
temporarily and will move to its own repository; nothing in this image depends
on it.

### Two requirements on the application image

1. **Provide `/etc/nginx/conf.d/vhost.conf`** with exactly one `server{}` block
   listening on `8080`.
2. **That vhost must define `/fpm-ping`** on `127.0.0.1` — the image
   `HEALTHCHECK` uses it. Copy the block from any template in `apps/`.

## Tags

| Tag | PHP | Status |
|---|---|---|
| `8.4` | 8.4 | current |
| `8.2` | 8.2 | migration bridge — **security support ends 2026-12-31** |

Published to **Docker Hub** as `docker.io/achelesstech/php-base`. Rebuilt weekly
by CI so Alpine and PHP patch releases land without anyone remembering. Renovate
then opens digest-bump PRs in the app repos.

CI needs two repository secrets to push:

| Secret | Value |
|---|---|
| `DOCKERHUB_USERNAME` | Docker Hub account with write access to `achelesstech` |
| `DOCKERHUB_TOKEN` | Access token from Docker Hub → Account Settings → Personal access tokens, scope **Read & Write** |

Use an access token, never the account password — a token is scoped and can be
revoked on its own. The same two secrets are expected by every app repo built
from [`apps/`](apps/). Pull is anonymous; nothing needs a login to consume the
image, though authenticated pulls get a higher rate limit.

## What's inside

**Extensions** — the union across Laravel, Drupal, Moodle, WordPress and Symfony:

```
apcu  bcmath  exif  gd  imagick  intl  ldap  mysqli  opcache  pcntl
pdo_mysql  pdo_pgsql  pgsql  redis  soap  zip
```

Plus everything the upstream `php:*-fpm-alpine` image already enables
(`mbstring`, `curl`, `xml`, `dom`, `sodium`, `openssl`, `sqlite3`, …), which is
why they are not recompiled here.

Xdebug and PCOV are **not** included. They were the only reason
`/usr/local/etc/php/conf.d` had to be writable by the runtime user. Add them in
a `dev` build stage in the app repo instead — see `apps/laravel13/Dockerfile`.

**Also present:** nginx, supervisor, tini, curl, composer 2.8.

**Deliberately absent:** `mariadb-client`, `postgresql-client`, `nodejs`. Add
them in the app image where they are needed.

## Runtime configuration

Everything numeric is an env var. The entrypoint renders PHP settings into
`/etc/php-runtime.d/zz-runtime.ini` (second entry in `PHP_INI_SCAN_DIR`, so it
wins) and pool settings into `php-fpm.d/zz-runtime.conf`.

### PHP

| Env | Default |
|---|---|
| `PHP_MEMORY_LIMIT` | `256M` |
| `PHP_UPLOAD_MAX_FILESIZE` / `PHP_POST_MAX_SIZE` | `64M` |
| `PHP_MAX_EXECUTION_TIME` / `PHP_MAX_INPUT_TIME` | `120` |
| `PHP_MAX_INPUT_VARS` | `5000` |
| `PHP_DATE_TIMEZONE` | `UTC` |
| `PHP_DISPLAY_ERRORS` | `Off` |
| `PHP_ERROR_REPORTING` | — |
| `PHP_SESSION_COOKIE_SECURE` | `1` — set `0` for plain-HTTP local dev |
| `PHP_SESSION_SAVE_HANDLER` / `PHP_SESSION_SAVE_PATH` | disk — **set to Redis before scaling past one replica** |
| `PHP_OPCACHE_ENABLE` | `1` |
| `PHP_OPCACHE_MEMORY` | `192` |
| `PHP_OPCACHE_MAX_FILES` | `20000` |
| `PHP_OPCACHE_VALIDATE_TIMESTAMPS` | `0` — set `1` for dev |

OPcache **JIT is off**. It gives close to nothing on request-scoped CMS
workloads, costs RSS per pool, and has a history of segfaults under FPM. Turn
it on per-app only with a benchmark behind it.

### PHP-FPM pool

| Env | Default |
|---|---|
| `FPM_PM` | `dynamic` |
| `FPM_MAX_CHILDREN` | `12` |
| `FPM_START_SERVERS` | `3` |
| `FPM_MIN_SPARE_SERVERS` / `FPM_MAX_SPARE_SERVERS` | `2` / `5` |
| `FPM_MAX_REQUESTS` | `500` |
| `FPM_PROCESS_IDLE_TIMEOUT` | `10s` |
| `FPM_REQUEST_TERMINATE_TIMEOUT` | — |
| `FPM_SLOWLOG_TIMEOUT` | — |

Sizing: `max_children ≈ (container memory − 128M) / average request RSS`.
Measure the average from `/fpm-status` rather than guessing.

## Operational behaviour

**Health.** `HEALTHCHECK` curls `/fpm-ping`, which goes through FastCGI. A
static nginx `return 200` health endpoint stays green while PHP-FPM is dead —
container "healthy", every request 502.

**Failure.** Both daemons are `autorestart=true`. If either exhausts
`startretries` and reaches `FATAL`, an event listener shuts supervisord down so
the container exits and the orchestrator restarts it. Supervisor's default is
to leave the program dead and keep running.

**Shutdown.** `stopsignal=QUIT` on both, nginx stopped first so it drains
before FPM does.

**Logs.** nginx access/error go to container stdout/stderr, not to files in the
writable layer. PHP-FPM error and access logs go to `/proc/self/fd/{1,2}`.

**Workers.** Containers that override `CMD` (`queue:work`, cron, …) run no
nginx, so the image healthcheck cannot pass. Replace or disable it in compose —
every template in `apps/` shows this.

**Client IP.** nginx trusts `X-Forwarded-For` from RFC1918 and applies
`real_ip_recursive`, so `REMOTE_ADDR` inside PHP is the real client. Without it
every request appears to come from Traefik and Moodle login throttling, Drupal
flood control and Laravel rate limiting all silently stop working. Loopback is
deliberately *not* trusted, which is what keeps the `/fpm-ping` ACL sound.
This is only as good as Traefik's `forwardedHeaders.trustedIPs` — see
[`docs/reverse-proxy.md`](docs/reverse-proxy.md).

**Security posture.** Runs as `www-data` 1000:1000. `/usr/local/etc/php/conf.d`
stays root-owned so a compromised worker cannot persist an `auto_prepend_file`
across restarts. There is no supervisor control socket — it would have given an
RCE a process-spawning channel, since FPM workers share its uid.

## Development

```bash
make build              # PHP 8.4
make build PHP=8.2
make test               # boots the image and asserts it actually works
make lint               # hadolint
make scan               # trivy
make shell
```

`make test` builds a fixture application on the base, boots it, and asserts 23
behaviours: PHP executing through FastCGI, uid/gid really being 1000:1000,
runtime env overrides landing, `REMOTE_ADDR` being the client rather than the
proxy, `conf.d` not being writable, no foreign-owned files baked in, logs
reaching stdout, and killing PHP-FPM bringing the container down. The previous
smoke test booted an image with no application and asserted a static nginx
response — it could not fail.

## Layout

```
Dockerfile
rootfs/
  etc/nginx/nginx.conf                    http{} only — no server{}
  etc/supervisor/supervisord.conf
  usr/local/bin/docker-entrypoint.sh
  usr/local/bin/healthcheck.sh
  usr/local/bin/nginx-validate.sh
  usr/local/bin/supervisor-fatal-listener.sh
  usr/local/etc/php/conf.d/zz-base.ini
  usr/local/etc/php-fpm.d/www.conf
apps/                                     templates to copy into app repos
traefik/                                  the edge proxy (temporary home)
docs/reverse-proxy.md                     Traefik + Cloudflare
test/                                     fixture app + behavioural test suite
.github/workflows/build-base.yml
```

Every config file is a real file under `rootfs/`. None are generated by
`RUN cat <<EOF` heredocs — that is how the previous revision shipped two
Dockerfiles that could not build (`chmod` parsed as a Dockerfile instruction)
and one that emitted invalid PHP from three levels of nested quoting.
