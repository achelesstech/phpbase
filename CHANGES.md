# Changes vs php-base-jul5.zip

## Fatal / functional bugs fixed

1. **Non-root entrypoint could not start the container.** The entrypoint
   (running as www-data) wrote `zz-runtime-overrides.ini` and toggled
   xdebug/pcov inside root-owned `/usr/local/etc/php/conf.d` — the redirect
   failed and `set -e` killed startup. The override file is now pre-created
   and chowned at build time, along with `/etc/nginx/conf.d`,
   `/etc/nginx/templates`, `/etc/supervisor/conf.d` and `/docker-entrypoint.d`.

2. **`$CHANGED && echo` under `set -e`.** Returned 1 when no overrides were
   set and aborted the entrypoint. Replaced with an explicit `if`.

3. **Broken DOCROOT selection.** The `[ -n "$DOCUMENT_ROOT" ] && … || … && …`
   chain always overwrote `DOCUMENT_ROOT` because of left-associative
   `&&`/`||`. Replaced with explicit if/elif/else in the entrypoint
   (`NGINX_DOCUMENT_ROOT` → `APP_ROOT/APP_PUBLIC_DIR` → `APP_ROOT`).

4. **Drush was never installed** (`composer require --no-update || true` only
   edits composer.json). Now installed for real if the project doesn't ship
   it. Dead `ARG DRUPAL_VERSION` removed.

5. **Queue/scheduler containers permanently "unhealthy".** They inherited the
   nginx-based image HEALTHCHECK while not running nginx. Replaced with
   process checks; one-shot `migrate` disables the healthcheck.

6. **Supervisor `user = www-data` per program** — a non-root supervisord
   cannot setuid; removed (supervisord already runs as www-data).

7. **Three conflicting registries** (`roneybd85/…`, `ghcr.io/yourorg/…`,
   `achelesstech/…`) unified into one `ARG BASE_IMAGE` per child Dockerfile.

8. Compose files referenced non-existent `compose-hooks/*.sh`; removed. The
   entrypoint now also runs non-executable hooks via `sh` (ro-mounts often
   lose the exec bit).

## Platform-specific corrections

### Moodle 5.1+
- Docroot moved to `/public` (5.1 restructure); `config.php` generated at the
  install root, outside the web root. `lib/setup.php` path auto-detected for
  pre/post-5.1 layouts.
- New `moodle` nginx profile: slasharguments URLs
  (`/pluginfile.php/…`, `/theme/styles.php/…`, `/lib/requirejs.php/….js`)
  now work — `try_files $fastcgi_script_name` after the pathinfo split, and
  the PHP location is ordered before the static-assets regex.
- `$CFG->sslproxy` written from `MOODLE_SSLPROXY` (default true) for Traefik
  TLS termination.
- Cron added: `MOODLE_RUN_CRON=true` registers a supervised in-container
  runner, or use the sidecar in `docker-compose.moodle.example.yml`.
- Install switched from git clone to the official release tarball
  (`MOODLE_BRANCH=501`); default was previously pinned to Moodle 4.5.
- XML-RPC removed everywhere — not required by Moodle 4.x+.

### Drupal 11
- New `drupal` nginx profile: image styles (`/sites/*/files/styles/`) fall
  back to `index.php` (previously 404 before derivative generation); PHP
  execution denied inside `sites/*/files`; `/update.php` path info works;
  private `/system/files/` routed through Drupal; vendor/composer files
  blocked.
- `INSTALL_APCU` build toggle added and enabled in the Drupal profile.
- Reverse-proxy settings (`$settings['reverse_proxy']`, trusted headers)
  appended to settings.php once, controlled by `DRUPAL_REVERSE_PROXY`.

### Laravel 13
- Base defaults to PHP 8.4 (Laravel 13 requires 8.3+; 13.3+ pulls Symfony 8
  components requiring 8.4).
- Contradictory `--no-autoloader --optimize-autoloader` cleaned up;
  `npm ci --include=dev` replaces deprecated `--production=false`.
- Init hook: `storage:link` added, `route:cache` failure warns instead of
  crashing, chown/chmod guarded for foreign-owned bind mounts.
- Scheduler uses `php artisan schedule:work` instead of a shell sleep loop.

## Traefik / reverse-proxy awareness (all profiles)

- nginx maps `X-Forwarded-Proto` → `HTTPS` fastcgi param, so PHP sees the
  correct scheme behind Traefik (secure cookies, generated URLs, `is_https`).
- Prod compose publishes no ports; the app joins an external `proxy` network
  with `traefik.http.services.*.loadbalancer.server.port=8080` labels.
- `session.cookie_secure=1` stays the default (correct behind TLS) and is now
  runtime-overridable via `PHP_SESSION_COOKIE_SECURE=0` for local HTTP dev.
- HSTS/TLS headers intentionally left to Traefik.

## Other improvements

- Nginx vhost is no longer baked at build time: per-platform templates
  (`generic`/`laravel`/`drupal`/`moodle`) in `/etc/nginx/templates`, rendered
  at container start from `NGINX_PROFILE` + env — same image, reconfigurable
  at `docker run` (`NGINX_DOCUMENT_ROOT`, `NGINX_CLIENT_MAX_BODY_SIZE`,
  `NGINX_FASTCGI_READ_TIMEOUT`).
- `/fpm-status` and `/fpm-ping` restricted to 127.0.0.1 by default.
- `opcache.enable_file_override` off (Drupal update.php issues).
- Secrets moved out of compose into `.env` (a real APP_KEY was committed);
  YAML anchors replace 4x-duplicated env blocks; obsolete `version:` removed.
- Postgres example pinned user/db to env; MariaDB Moodle example added with
  required charset/innodb flags.
- Makefile: sortable date tags (`%Y%m%d-%H%M`), PHP 8.4 default,
  `nginx -t` added to smoke test.
- `icu-data-full` added when intl is on (Alpine ships stripped ICU data;
  Moodle/Drupal locale handling needs the full set).
