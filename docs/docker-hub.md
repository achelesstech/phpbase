# achelesstech/php-base

PHP-FPM and nginx on Alpine, supervised by s6, non-root (`www-data`
1000:1000), built for **Laravel, Drupal, Moodle and WordPress** behind a
TLS-terminating proxy (Traefik, optionally with Cloudflare). Rebuilt within
about 6 hours of a new official PHP image, a new Alpine image or a pending
Alpine package fix, and tested under the production run flags and against real installs of all four
frameworks before anything is tagged.

## Tags

| Tag | |
|---|---|
| `8.2` `8.3` `8.4` `8.5` | the newest build of each PHP line. Moves with every rebuild: **pin by digest**, `php-base:8.4@sha256:…` |
| `8.4.27` | the newest build of one PHP patch release |
| `8.4.27-20261026` | one build; never moves (a second build that day is `8.4.27-20261026.2`) |
| `…-dev` | every tag has a `-dev` twin: Composer, git, Xdebug and PCOV (both off), PHP sources and `phpize`. For local development and `composer install` build stages |
| `latest`, `latest-dev` | the newest stable line (8.5). Not for production |
| `8.6-rc`, `8.6-rc-dev` | the pre-release canary, when it builds and passes |

There are no `-alpine3.x` tags: a tag pinned to one Alpine release stops
receiving PHP updates. PHP 8.2's security support ends 2026-12-31.

Every image is signed with cosign (keyless, GitHub OIDC) and carries an SBOM
and provenance:

```sh
cosign verify docker.io/achelesstech/php-base:8.4 \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github.com/achelesstech/phpbase/\.github/workflows/build-base\.yml@'
```

## Use

```dockerfile
FROM docker.io/achelesstech/php-base:8.4@sha256:<runtime digest>
USER root
COPY . /var/www/html
RUN ln -s /etc/nginx/presets/laravel.conf /etc/nginx/conf.d/default.conf \
 && php-base-validate
USER www-data
```

Code stays root-owned. Under `--read-only`, every path the app writes at
runtime (caches, logs, uploads, sessions) needs a volume or a tmpfs. Composer
is only in `-dev`, so install dependencies in a `-dev` build stage. Complete,
tested templates: [Laravel](https://github.com/achelesstech/phpbase/tree/main/examples/laravel),
[Drupal](https://github.com/achelesstech/phpbase/tree/main/examples/drupal), [WordPress](https://github.com/achelesstech/phpbase/tree/main/examples/wordpress),
[Moodle](https://github.com/achelesstech/phpbase/tree/main/examples/moodle).

| Preset | Docroot |
|---|---|
| `laravel.conf` | `/var/www/html/public` (only `index.php` executes) |
| `drupal.conf` | `/var/www/html/web` |
| `wordpress.conf` | `/var/www/html` |
| `moodle.conf` | `/var/www/html/public` (Moodle 5.1+, Routing Engine) |
| `moodle-legacy.conf` | `/var/www/html` (Moodle 5.0 and older) |

Add `location` blocks in `/etc/nginx/server.d/*.conf`, or ship your own
`server{}` on 8080. Either way, define no health paths: `/fpm-ping`,
`/fpm-status` and `/nginx-status` are built in, on `127.0.0.1:8081` only.

Run it with the hardened flags it is tested under:

```sh
docker run --read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,size=256m \
  --cap-drop ALL --security-opt no-new-privileges --pids-limit 256 --memory 1g \
  -p 8080:8080 my-app
```

Give `/tmp` a `size=` (or use a volume): uploads and caches live there, and
the FPM pool is sized from the memory limit minus that size.

## Roles: one image, any command

```yaml
app:       {}                                                          # nginx + php-fpm (CMD php-base-web)
queue:     { command: [php, artisan, queue:work, --max-time=3600] }
scheduler: { command: [php-base-every, "60", php, artisan, schedule:run] }
```

`php-base-every SECONDS CMD…` is a container-native cron: aligned to the
clock, never overlapping, graceful on SIGTERM. The built-in healthcheck picks
the probe by role:
- web: `/fpm-ping` on `127.0.0.1:8081`, through FastCGI;
- `php-base-every`: its heartbeat;
- any other command: none.

Small sites can run `SCHEDULER_COMMAND` and `WORKER_COMMAND` inside the web
container instead.

## Configuration (env, applied at every start)

| Variable | Default | Effect |
|---|---|---|
| `PHP_MEMORY_LIMIT`, `PHP_UPLOAD_MAX_FILESIZE`, `PHP_POST_MAX_SIZE`, `PHP_MAX_EXECUTION_TIME`, `PHP_MAX_INPUT_VARS`, `PHP_SESSION_*`, `PHP_OPCACHE_*`, … | production values | php.ini overrides |
| `PHP_INI_EXTRA` | | extra ini lines, verbatim |
| `PHP_DISABLE_FUNCTIONS` | unset | `disable_functions` for web requests only |
| `FPM_MAX_CHILDREN` | `auto` | from the memory limit: (limit − OPcache − 64 MiB − `/tmp` tmpfs) / `FPM_WORKER_MEMORY`, 2 to 64 |
| `FPM_WORKER_MEMORY` | `64M` | per-worker estimate for `auto` |
| `FPM_REQUEST_TERMINATE_TIMEOUT` | `300s` | |
| `FPM_PM`, `FPM_MAX_REQUESTS`, `FPM_SLOWLOG_TIMEOUT`, `FPM_ACCESS_LOG`, `FPM_POOL_EXTRA`, … | | the FPM pool |
| `NGINX_WORKER_PROCESSES` | `2` | |
| `NGINX_GZIP` | `0` | dynamic gzip; Traefik already compresses. `gzip_static` is always on |
| `NGINX_ACCESS_LOG` | `off` | `main` or `json`; Traefik already logs |
| `NGINX_FASTCGI_READ_TIMEOUT` | `300s` | |
| `NGINX_CLIENT_MAX_BODY_SIZE` | PHP's `post_max_size` | |
| `NGINX_REAL_IP_FROM` | private ranges | proxies trusted for `X-Forwarded-For` |
| `NGINX_TRUST_CLOUDFLARE` | `1` | also trust Cloudflare's edge ranges |
| `HEALTHCHECK_MODE` | `auto` | `auto`, `fpm`, `http`, `tcp`, `heartbeat`, `none` |
| `HEALTHCHECK_URL` | | e.g. `http://127.0.0.1:8080/up` |
| `SCHEDULER_COMMAND`, `SCHEDULER_INTERVAL`, `WORKER_COMMAND` | | in-container jobs |
| `PHP_BASE_STRICT` | `0` | `1` refuses hooks that aren't root-owned or are group/other-writable |

nginx keeps connections alive for 120 s, longer than Traefik's 90 s idle
reuse, so Traefik never reuses a connection nginx is closing.

## Inside

Extensions: apcu, bcmath, exif, gd (webp, avif), gmp, igbinary, imagick (jpeg,
png, gif, webp, avif, heic), intl (full ICU), ldap, memcached, mysqli,
opcache, pcntl, pdo_mysql, pdo_pgsql, pdo_sqlite, pgsql, redis (igbinary,
zstd, lz4), soap, sockets, sodium, uploadprogress, zip, plus PHP's defaults.

Not in the runtime image: Python, supervisord, Composer, compilers, PHP
sources. ImageMagick reads and writes only an allowlist of raster formats,
with no delegates and a memory cap per operation.

## Hardening

- Every process runs as `www-data`; PID 1 is tini. No setuid files.
- PHP-FPM listens on a Unix socket only; nothing listens on 9000.
- Config, presets, hooks, scripts and s6 definitions are root-owned.
- The container writes only under `/tmp`; rendered config there is wiped and
  regenerated at every start.
- Entrypoint logs go to stderr, so a command's stdout stays clean for pipes.

Source, full reference and security model: <https://github.com/achelesstech/phpbase>
