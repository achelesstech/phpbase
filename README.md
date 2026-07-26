# PHP Base Image — Production Grade (Traefik-fronted)

A configurable, multi-stage Docker base image for running PHP applications
(Laravel 13, Drupal 11, Moodle 5.1+, WordPress, Symfony, Mautic…) with
**Nginx + PHP-FPM + Supervisor** on Alpine, designed to sit **behind an
external Traefik reverse proxy** that terminates TLS.

```
Traefik (external, TLS) ──► :8080 ┌──────────────────────────────────────┐
                                  │  Nginx ──► PHP-FPM   Supervisor      │
                                  │  vhost rendered at start from        │
                                  │  NGINX_PROFILE template              │
                                  │  /docker-entrypoint.d/*.sh hooks     │
                                  │  tini PID 1 · non-root (www-data)    │
                                  └──────────────────────────────────────┘
```

| Stage | Purpose | Kept? |
|---|---|---|
| `ext-builder` | Compiles PHP extensions with build deps | No |
| `composer-bin` | Provides Composer binary | binary copied |
| `runtime` | Final image, runtime deps only | **Yes** |

## Quick start

```bash
make build-laravel      # PHP 8.4, MySQL+PgSQL+Redis, public/ docroot
make build-drupal       # PHP 8.4, +APCu, web/ docroot, drupal vhost
make build-moodle       # PHP 8.4, +SOAP/LDAP/pspell/gs, public/ docroot (5.1), moodle vhost

# Custom
docker build \
  --build-arg PHP_VERSION=8.4 \
  --build-arg INSTALL_REDIS=true \
  --build-arg NGINX_PROFILE=laravel \
  -t my-php-base .
```

## Runtime vhost (new)

The nginx vhost is **rendered at container start**, not baked at build time.
Selection and values come from env, so the same image is reconfigurable at
`docker run`:

| Env | Default | Meaning |
|---|---|---|
| `NGINX_PROFILE` | `generic` | `generic` \| `laravel` \| `drupal` \| `moodle` |
| `NGINX_DOCUMENT_ROOT` | *(unset)* | explicit docroot override |
| `APP_PUBLIC_DIR` | `public` | docroot = `$APP_ROOT/$APP_PUBLIC_DIR` (empty ⇒ `$APP_ROOT`) |
| `NGINX_CLIENT_MAX_BODY_SIZE` | `100M` | upload limit |
| `NGINX_FASTCGI_READ_TIMEOUT` | `300` | FPM read timeout |

Platform profiles encode the platform-specific requirements:

- **drupal** — image-styles fallback to index.php, PHP execution denied in
  `sites/*/files`, `/update.php` path info, private `/system/files/` routing.
- **moodle** — Moodle 5.1 `/public` docroot, slasharguments
  (`/pluginfile.php/...`) via `$fastcgi_script_name`, PHP location ordered
  before static assets so `/lib/requirejs.php/1/all.js` executes.
- **laravel / generic** — standard front controller.

## Reverse proxy (Traefik) notes

- Container listens on plain HTTP **:8080**; publish nothing — attach it to
  the shared Traefik network and set
  `traefik.http.services.<name>.loadbalancer.server.port=8080`.
- nginx maps `X-Forwarded-Proto` into the `HTTPS` fastcgi param, so PHP sees
  the real scheme (secure cookies and generated URLs work).
- Moodle: set `MOODLE_URL=https://…` and leave `MOODLE_SSLPROXY=true`.
- Drupal: reverse-proxy trust is appended to settings.php automatically
  (disable with `DRUPAL_REVERSE_PROXY=false`; override CIDRs with
  `DRUPAL_REVERSE_PROXY_ADDRESSES`).
- Laravel: configure trusted proxies in `bootstrap/app.php`
  (`->trustProxies(at: '*')` or your proxy CIDRs).
- HSTS / TLS headers belong on Traefik, not in this image.

## Build arguments

### Extensions (compiled in `ext-builder`)

| Argument | Default | Adds |
|---|---|---|
| `INSTALL_GD` | `true` | gd (freetype, jpeg, webp, avif) |
| `INSTALL_INTL` | `true` | intl (+ full ICU data) |
| `INSTALL_MYSQL` | `true` | pdo_mysql, mysqli |
| `INSTALL_POSTGRESQL` | `true` | pdo_pgsql, pgsql |
| `INSTALL_SQLITE` | `false` | pdo_sqlite |
| `INSTALL_REDIS` | `false` | redis (PECL) |
| `INSTALL_APCU` | `false` | apcu (PECL) — enable for Drupal |
| `INSTALL_MEMCACHED` | `false` | memcached (PECL) |
| `INSTALL_IMAGEMAGICK` | `false` | imagick (PECL) |
| `INSTALL_LDAP` | `false` | ldap |
| `INSTALL_SOAP` | `false` | soap |
| `INSTALL_PSPELL` | `false` | pspell |
| `INSTALL_XDEBUG` / `INSTALL_PCOV` | `false` | installed disabled; enable at runtime with `ENABLE_XDEBUG=true` / `ENABLE_PCOV=true` |

Always included: mbstring, exif, pcntl, bcmath, curl, xml, zip, opcache —
plus sodium/openssl/dom etc. from the official php-fpm-alpine base (covers
Moodle 5's required sodium).

Removed: `INSTALL_XMLRPC` (Moodle no longer needs it).

### PHP / FPM / Nginx tuning (defaults match the Dockerfile)

| Argument | Default |
|---|---|
| `PHP_MEMORY_LIMIT` | `512M` |
| `PHP_UPLOAD_MAX_FILESIZE` / `PHP_POST_MAX_SIZE` | `100M` |
| `PHP_MAX_EXECUTION_TIME` | `300` |
| `PHP_MAX_INPUT_VARS` | `10000` |
| `PHP_OPCACHE_MEMORY` / `PHP_OPCACHE_MAX_FILES` | `256` / `20000` |
| `PHP_OPCACHE_VALIDATE_TIMESTAMPS` | `0` |
| `FPM_PM` / `FPM_MAX_CHILDREN` | `dynamic` / `20` |
| `FPM_START_SERVERS` / min / max spare | `3` / `2` / `5` |
| `NGINX_WORKER_CONNECTIONS` | `1024` |

### Runtime env overrides (no rebuild)

`PHP_MEMORY_LIMIT`, `PHP_UPLOAD_MAX_FILESIZE`, `PHP_POST_MAX_SIZE`,
`PHP_MAX_EXECUTION_TIME`, `PHP_DISPLAY_ERRORS`, `PHP_ERROR_REPORTING`,
`PHP_SESSION_COOKIE_SECURE` (set `0` for plain-HTTP local dev),
`PHP_OPCACHE_VALIDATE_TIMESTAMPS`, `ENABLE_XDEBUG`, `ENABLE_PCOV`.

## Platform version matrix

| Platform | Min PHP | This image | Docroot | Notes |
|---|---|---|---|---|
| Laravel 13 | 8.3 (8.4 for ≥13.3) | 8.4 | `public/` | `NGINX_PROFILE=laravel` |
| Drupal 11 | 8.3 | 8.4 | `web/` | `NGINX_PROFILE=drupal`, APCu on |
| Moodle 5.1 | 8.2 | 8.4 | `public/` (5.1 restructure) | `NGINX_PROFILE=moodle`, cron required |

## Moodle specifics

- `MOODLE_BRANCH=501` build arg selects the release tarball (5.1.x).
- `config.php` generated from `MOODLE_DB_*`, `MOODLE_URL`, `MOODLE_SSLPROXY`
  at the install root — outside the web root, per the 5.1 layout.
- Cron: set `MOODLE_RUN_CRON=true` (supervised in-container runner) **or**
  use the sidecar in `docker-compose.moodle.example.yml`. One of the two is
  mandatory for a functioning site.
- `moodledata` lives at `/var/moodledata` (named volume; never inside the
  install root).

## Health & introspection

- `GET /healthz` — nginx liveness (used by the image HEALTHCHECK)
- `GET /fpm-ping`, `GET /fpm-status` — restricted to 127.0.0.1 by default

## Files

```
Dockerfile                         base image
Dockerfile.{laravel,drupal,moodle,wordpress,symfony}
rootfs/usr/local/bin/docker-entrypoint.sh
rootfs/etc/nginx/templates/*.conf.tpl   per-platform vhosts
docker-compose.example.yml         Laravel dev (local ports)
docker-compose.prod.example.yml    Laravel prod behind Traefik
docker-compose.moodle.example.yml  Moodle 5.1 prod behind Traefik + cron
.env.example                       copy to .env — no secrets in compose
Makefile                           profile builds (PHP 8.4 default)
CHANGES.md                         full list of fixes vs previous revision
```
