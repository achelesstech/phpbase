# achelesstech/php-base

PHP-FPM + nginx + supervisor on Alpine, non-root (www-data 1000:1000), built
for **Laravel, Drupal, Moodle and WordPress** behind a TLS-terminating proxy
(Traefik, Cloudflare). Rebuilt **every week** from the newest PHP patch
release and the newest Alpine packages, tested against real installs of all
four frameworks before anything is tagged.

## Tags

| Tag | |
|---|---|
| `8.2` `8.3` `8.4` `8.5` | one line per PHP minor; **pin by digest**: `php-base:8.4@sha256:…` |
| `8.4.27`, `8.4-alpine3.24` | floating within a patch release / an Alpine series |
| `8.4.27-YYYYMMDD` | one per build |
| `…-dev` | + Xdebug (off until `XDEBUG_MODE` is set), PCOV (off), git |
| `latest` | newest stable line; not for production |
| `8.6-rc` | pre-release canary, when it builds |

Signed with cosign (keyless, GitHub OIDC); SBOM and provenance attached.

```sh
cosign verify docker.io/achelesstech/php-base:8.4 \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github.com/achelesstech/phpbase/'
```

## Use

```dockerfile
FROM docker.io/achelesstech/php-base:8.4@sha256:<digest>
COPY --chown=root:root . /var/www/html
USER root
RUN chown -R www-data:www-data storage bootstrap/cache \
 && ln -s /etc/nginx/presets/laravel.conf /etc/nginx/conf.d/default.conf \
 && nginx-validate.sh
USER www-data
```

| Preset | Docroot |
|---|---|
| `laravel.conf` | `/var/www/html/public` (front controller only) |
| `drupal.conf` | `/var/www/html/web` |
| `wordpress.conf` | `/var/www/html` |
| `moodle.conf` | `/var/www/html/public` (Moodle 5.1+, Routing Engine) |
| `moodle-legacy.conf` | `/var/www/html` (Moodle ≤ 5.0) |

Add your own `location` blocks in `/etc/nginx/server.d/*.conf`, or ship a full
vhost that includes `/etc/nginx/php-base/health.conf` (the healthcheck needs
`/fpm-ping`).

Extensions: apcu, bcmath, exif, gd (webp, avif), gmp, igbinary, imagick (jpeg,
webp, heic, avif), intl (full ICU), ldap, memcached, mysqli, opcache, pcntl,
pdo_mysql, pdo_pgsql, pdo_sqlite, pgsql, redis (igbinary, zstd, lz4), soap,
sockets, sodium, uploadprogress, zip, plus PHP's defaults. Composer 2 included.

## Roles: one image, any command

```yaml
app:       {}                                                    # nginx + php-fpm
queue:     { command: [php, artisan, queue:work] }
scheduler: { command: [php-base-every, "60", php, artisan, schedule:run] }
```

`php-base-every SECONDS CMD` is a container-native cron: it is aligned to the
clock, never overlaps runs, and stops gracefully. The built-in healthcheck picks
the right probe per role:
- web: `/fpm-ping` through FastCGI;
- scheduler: the heartbeat file;
- worker: none.

Small sites can instead run
`SCHEDULER_COMMAND` / `WORKER_COMMAND` inside the web container.

## Configuration (env, applied at start)

| Variable | Effect |
|---|---|
| `PHP_MEMORY_LIMIT`, `PHP_UPLOAD_MAX_FILESIZE`, `PHP_POST_MAX_SIZE`, `PHP_MAX_EXECUTION_TIME`, `PHP_MAX_INPUT_VARS`, `PHP_SESSION_SAVE_HANDLER`, `PHP_SESSION_SAVE_PATH`, `PHP_OPCACHE_*`, … | php.ini overrides |
| `PHP_INI_EXTRA` | extra ini lines, verbatim |
| `FPM_PM`, `FPM_MAX_CHILDREN`, `FPM_MAX_REQUESTS`, `FPM_REQUEST_TERMINATE_TIMEOUT`, `FPM_SLOWLOG_TIMEOUT`, `FPM_ACCESS_LOG`, `FPM_POOL_EXTRA` | FPM pool |
| `NGINX_CLIENT_MAX_BODY_SIZE` | default: PHP's effective `post_max_size` |
| `NGINX_REAL_IP_FROM` | trusted proxies; default private ranges |
| `NGINX_TRUST_CLOUDFLARE` | default `1` (Cloudflare edge ranges trusted for X-Forwarded-For) |
| `NGINX_ACCESS_LOG` | `main` \| `json` \| `off` |
| `HEALTHCHECK_MODE` | `auto` \| `fpm` \| `http` \| `tcp` \| `heartbeat` \| `none` |
| `HEALTHCHECK_URL` | e.g. `http://127.0.0.1:8080/up` |

Production defaults: `zend.assertions=-1`, `expose_php=Off`, errors to stderr,
`session.cookie_secure=1`, `session.upload_progress.enabled=Off`, OPcache on
with timestamps off, JIT off.

## Hardening

- Runs as non-root; there is no supervisor control socket.
- Config, presets, hooks and binaries are root-owned.
- At runtime the image writes only under `/tmp`, so this works:
  ```yaml
  read_only: true
  tmpfs: [/tmp]
  ```
- Rendered config is wiped and regenerated at every start.
- Entrypoint logs go to stderr, so a command's stdout stays clean for pipes.

Source and tests: <https://github.com/achelesstech/phpbase>
