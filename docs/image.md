# The image

What is in `achelesstech/php-base`, what it does at start, and every setting
it reads. Tags are in the [repository README](../README.md#tags); hardening
and the ImageMagick policy are in [`security.md`](security.md).

- [Variants](#variants)
- [Contents](#contents)
- [The runtime contract](#the-runtime-contract)
- [What happens at start](#what-happens-at-start)
- [Roles: one image, any command](#roles-one-image-any-command)
- [nginx: presets and your own vhost](#nginx-presets-and-your-own-vhost)
- [Healthcheck](#healthcheck)
- [Stopping and failure](#stopping-and-failure)
- [Environment variables](#environment-variables)
- [Tuning](#tuning)
- [Commands in the image](#commands-in-the-image)

## Variants

| Variant | Tag | For |
|---|---|---|
| runtime | `X.Y` | production |
| dev | `X.Y-dev` | local development, and the build stage that runs `composer install` |

**runtime** is a clean `alpine:<minor>` with PHP copied in from the official
`php:X.Y-fpm-alpine` image. `<minor>` is the Alpine release that PHP image was
built on, because PHP's binaries link against that branch's libraries. The
build fails if the two differ.

**dev** is the runtime plus everything that builds things:
- Composer 2, git, unzip, patch, openssh-client;
- PHP sources (`/usr/src/php.tar.xz`), headers, `phpize`, `php-config`, the
  `docker-php-ext-*` helpers, PEAR/PECL where the line still ships them, and
  `PHPIZE_DEPS` with the official image's value. An app can compile its own
  extension as root with `apk add $PHPIZE_DEPS && docker-php-ext-install …`;
- Xdebug and PCOV, installed but off (`xdebug.mode=off`, `pcov.enabled=0`);
- `zz-dev.ini`: assertions on, errors displayed, `error_reporting=E_ALL`,
  OPcache rechecks file times, `session.cookie_secure=0` for plain-HTTP
  localhost;
- `COMPOSER_HOME=/tmp/composer`.

Never run `-dev` in production: it displays errors, and it carries Composer,
git and PHP's build files: tools an attacker can use, and production never
needs them.

## Contents

**PHP extensions** (the union Laravel, Drupal, Moodle and WordPress need):

```
apcu  bcmath  exif  gd (freetype, jpeg, webp, avif)  gmp  igbinary
imagick (jpeg, png, gif, webp, avif, heic)  intl (full ICU data)  ldap
memcached (igbinary, json, session, sasl)  mysqli  opcache  pcntl  pdo_mysql
pdo_pgsql  pgsql  redis (igbinary, zstd, lz4)  soap  sockets  uploadprogress  zip
```

plus what the official image builds in: ctype, curl, dom, fileinfo, iconv
(GNU libiconv, so `//TRANSLIT` works), mbstring, openssl, pdo_sqlite, phar,
posix, session, simplexml, sodium, sqlite3, tokenizer, xml, xmlreader,
xmlwriter, zlib, and argon2 password hashing. PECL versions are pinned in the
Dockerfile and updated by Renovate.

**Alpine packages:** ca-certificates, curl, tzdata, tini, s6, nginx,
imagemagick with its heic, jpeg and webp coders, icu-data-full, and the
libraries PHP and its extensions link (worked out with `scanelf` at build
time, so an extension can never ship without its library).

**Not in the runtime image:** Python, supervisord, Composer, compilers, PHP
sources and headers, PEAR/PECL, `php-cgi`, `phpdbg`, any setuid or setgid
file. The build fails if one of them appears. Database clients, `nodejs` and
`ghostscript` are deliberately absent too: add them in the app image that
needs them.

**Labels:** the OCI set, where `org.opencontainers.image.base.name` and
`.base.digest` name the Alpine image, plus
`io.github.achelesstech.php-base.upstream-image`, `.upstream-digest`,
`.php-version`, `.alpine-version` and `.variant`. The same facts are in
`/etc/php-base/release`, which `php-base-info` prints.

## The runtime contract

| | |
|---|---|
| User | `www-data`, uid 1000, gid 1000. The upstream uid/gid 82 owns nothing |
| PID 1 | `tini`, which forwards signals; every other process runs as `www-data` |
| Public port | 8080 (nginx) |
| Status listener | `127.0.0.1:8081`: `/fpm-ping`, `/fpm-status`, `/nginx-status`. Unreachable from outside the container |
| PHP-FPM | the Unix socket `/tmp/php-base/php-fpm.sock`, mode 0660. Nothing listens on 9000 |
| Writes | only under `/tmp`. Config, presets, hooks, scripts and s6 service definitions are root-owned and read-only |
| App root | `/var/www/html` (`APP_ROOT`), the `WORKDIR` |
| Logs | everything goes to the container's stdout/stderr; no log file is written |

**Everything the container writes is under `/tmp`**, so it runs with a
read-only root filesystem and a tmpfs (or a volume) on `/tmp`. The entrypoint
wipes and re-renders `/tmp/php-base` at every start:

```
/tmp/php-base/
  role                     web or cli; healthcheck.sh reads it
  php/zz-runtime.ini       PHP_* overrides (the last ini scan dir, so it wins)
  fpm/zz-runtime.conf      pool size and FPM_* overrides (included last)
  nginx/main.d/, http.d/   worker count, body limit, real IP, timeouts, log, gzip
  nginx/tmp/               nginx's request-body and FastCGI buffers
  php-fpm.sock, nginx.pid
  s6/                      s6's scan and state directories (web role)
  heartbeat.NAME           touched by php-base-every
  home/                    $HOME
```

Because the directory is wiped first, anything a compromised PHP process
planted there (an `.ini` with `auto_prepend_file`, an nginx include) is gone
before PHP or nginx reads it again.

**`$HOME` is ephemeral.** `/home/www-data` is a symlink to
`/tmp/php-base/home`, which the entrypoint creates (mode 0750) at every
start. It is empty after each restart, so keep nothing there that has to
survive. If you bypass the entrypoint (`docker run --entrypoint sh …`), the
symlink points at nothing until something creates `/tmp/php-base/home`. It is
a symlink because the root filesystem is read-only and a real directory there
could never be written.

**Uploads and caches use `/tmp`.** nginx buffers request bodies in
`/tmp/php-base/nginx/tmp/`, PHP writes uploaded files to `/tmp`, and
ImageMagick's pixel-cache files go there too. On a tmpfs all of that is RAM,
charged to the container's memory limit. Size the tmpfs for at least
2 × `post_max_size` + 32 MB (nginx's buffered copy and PHP's copy of an
upload exist at the same time): 256 MB for the default 64M. For large uploads,
mount a volume on `/tmp` instead.

## What happens at start

`docker-entrypoint.sh` runs as `www-data`, logs to stderr (stdout belongs to
the command, so `docker compose run --rm app php artisan route:list --json | jq`
works), and then:

1. resets `/tmp/php-base` and creates `$HOME`;
2. decides the role from the command (below);
3. renders the PHP ini overrides from `PHP_*`;
4. sizes and renders the FPM pool (`FPM_MAX_CHILDREN=auto` logs one line, see
   [Tuning](#tuning));
5. renders the nginx settings;
6. for the web role, renders the s6 scan directory;
7. runs the application hooks, `/docker-entrypoint.d/*.sh`, in name order;
8. for the web role, tests the nginx and FPM configuration, so a bad env value
   gives one clear error instead of a crash loop;
9. execs the command.

**Hooks** run at every start, in every role. A hook that anyone but root could
modify would let a compromised PHP process run code at the next start, so the
entrypoint checks each one: a hook that isn't root-owned, or that is writable
by group or others, logs a warning. `PHP_BASE_STRICT=1` turns the warning
into a refusal to start. Copy hooks without `--chown` (root-owned, mode 0755
or 0644). A hook without the exec bit runs through `sh`; a symlinked hook is
judged by the file it points to. Hook output goes to stderr.

Steps 3 to 5 run in every role, so `PHP_*` settings apply to CLI commands as
well.

## Roles: one image, any command

| Command | Role | What runs |
|---|---|---|
| `php-base-web` (the default `CMD`) | web | s6 supervises php-fpm and nginx, plus the scheduler and worker when `SCHEDULER_COMMAND` / `WORKER_COMMAND` are set |
| anything else | cli | that command, directly: a queue worker, a scheduler, a migration, a one-off |

```yaml
services:
  app:       {}                                                          # web
  queue:     { command: [php, artisan, queue:work, --max-time=3600] }    # cli
  scheduler: { command: [php-base-every, "60", php, artisan, schedule:run] }
  migrate:   { command: [php, artisan, migrate, --force], profiles: [ops] }
```

`php-base-every SECONDS COMMAND…` is the container-native cron. It runs the
command at multiples of `SECONDS` on the wall clock (`:00` of every minute for
60), never overlaps runs (a run longer than the interval skips the missed
ticks), lets a run in progress finish on SIGTERM, and touches a heartbeat at
start and after every successful run, so the healthcheck can tell when the job keeps failing.
`--no-align` runs immediately and then every `SECONDS`; `--once` runs once;
`--name NAME` names the heartbeat.

**Small sites** can run the scheduler and a worker inside the web container
instead of separate ones:
- `SCHEDULER_COMMAND` runs every `SCHEDULER_INTERVAL` seconds (default 60)
  through `php-base-every`;
- `WORKER_COMMAND` runs continuously and is restarted, after at least a
  second, whenever it exits. Laravel's `queue:work --max-time` relies on that.

Both are parsed by a shell, so quotes and arguments with spaces work as they
would on a command line, and both run in `APP_ROOT`. If either exits, the web
container stays up.

A v1 app image that still runs `supervisord` fails at start with a message
naming `php-base-web`: supervisord and `/etc/supervisor` are gone.

## nginx: presets and your own vhost

`/etc/nginx/nginx.conf` is the `http{}` block only. The app supplies exactly
one `server{}` on 8080 in `/etc/nginx/conf.d/`, usually a symlink to a preset:

```dockerfile
RUN ln -s /etc/nginx/presets/laravel.conf /etc/nginx/conf.d/default.conf \
 && php-base-validate
```

| Preset | Docroot |
|---|---|
| `laravel.conf` | `/var/www/html/public`; only `index.php` executes |
| `drupal.conf` | `/var/www/html/web` |
| `wordpress.conf` | `/var/www/html` |
| `moodle.conf` | `/var/www/html/public` (Moodle 5.1+, Routing Engine) |
| `moodle-legacy.conf` | `/var/www/html` (Moodle 5.0 and older) |

Each preset's header explains its rules. To extend one without forking it,
put extra `location` blocks in `/etc/nginx/server.d/*.conf` at build time
(root-owned); the presets include them before their catch-all blocks, so they
win. An app that writes its own vhost includes
`/etc/nginx/php-base/fastcgi-php.conf` in its PHP location and passes to
`php_fpm`. It does not need to define any status or health path: those live on
the internal listener.

**Fixed `http{}` settings** and why:
- `keepalive_timeout 120s`, `keepalive_requests 10000`: longer than Traefik's
  90 s idle reuse of backend connections, so nginx never closes a connection
  Traefik is about to reuse (which would be a 502).
- **No dynamic gzip** by default: Traefik compresses, and compressing twice
  wastes CPU. `gzip_static on` still serves a pre-compressed `foo.css.gz` for
  `foo.css`, with `Vary: Accept-Encoding`. `NGINX_GZIP=1` turns dynamic gzip on
  for deployments without such a proxy.
- **Access log off** by default: Traefik already logs every request.
  `NGINX_ACCESS_LOG=main` or `json` turns it on.
- `open_file_cache`, with lookup errors not cached, so a file uploaded a
  moment ago is found.
- `SERVER_PORT` comes from `X-Forwarded-Port` when that is a plain number, and
  `HTTPS=on` from `X-Forwarded-Proto: https`, so URLs an app builds are right
  behind TLS termination.
- The real client IP comes from `X-Forwarded-For`, trusted only from private
  ranges and (by default) Cloudflare's edge, with `real_ip_recursive`. See
  [`reverse-proxy.md`](reverse-proxy.md).
- `client_max_body_size` follows PHP's effective `post_max_size`, so an upload
  PHP allows is not refused by nginx with a 413.
- Request buffering stays on: it stops a slow upload from tying up an FPM
  worker.

Security headers are not set at `http{}` level, because a location with its
own `add_header` drops every inherited one. The presets include
`/etc/nginx/php-base/security-headers.conf` where they need it, or set them
once on Traefik.

## Healthcheck

```
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --start-interval=2s --retries=3 CMD healthcheck.sh
```

Every 2 s while the container starts, so Traefik, which routes only to
healthy containers, gets a new container within seconds. It needs Docker 25
or newer. `HEALTHCHECK_MODE` picks the probe; the default `auto` chooses by
role:

| Mode | Probe | `auto` picks it for |
|---|---|---|
| `fpm` | `http://127.0.0.1:8081/fpm-ping` must answer `pong`; also `HEALTHCHECK_URL`, if set | the web role |
| `heartbeat` | the last successful `php-base-every` run is at most `HEALTHCHECK_MAX_AGE` seconds old | a `php-base-every` container |
| `none` | always healthy | any other command (a queue worker cannot be probed generically) |
| `http` | `HEALTHCHECK_URL` returns 2xx/3xx | — |
| `tcp` | something listens on `127.0.0.1:HEALTHCHECK_PORT` | — |

`/fpm-ping` goes through FastCGI, so it fails when PHP-FPM is dead, unlike a
static `return 200` that nginx answers alone. Set `HEALTHCHECK_URL` (for
example `http://127.0.0.1:8080/up`, Laravel's health route) to also prove the
application boots.

## Stopping and failure

- **`docker stop`** sends SIGTERM to tini, which forwards it to s6. nginx goes
  first, with SIGQUIT: it stops accepting connections and finishes the
  requests in flight. Then php-fpm gets SIGQUIT, and the scheduler and worker
  SIGTERM. The container exits 0. The kill timeouts are 15 s for nginx, 30 s
  for php-fpm and 120 s for the scheduler and worker, so set compose's
  `stop_grace_period` to cover what you run.
- **nginx or php-fpm dies on its own:** the whole container exits 1 within 5 s, and the restart policy takes over. Without this, the container
  would stay "running" while every request got a 502.
- **The scheduler or worker exits:** s6 restarts it and the container stays
  up.

## Environment variables

Applied at every start; nothing needs a rebuild. Unset means the default in the
table.

### PHP

Rendered into `/tmp/php-base/php/zz-runtime.ini`, which loads after the
image's `zz-base.ini`. They apply to web requests and CLI commands alike.
Values with characters other than letters, digits and `_ . / : + @ -` are
quoted, so a Redis save path with `?` and `&` works. Double quotes are refused.

| Variable | ini setting | Default |
|---|---|---|
| `PHP_MEMORY_LIMIT` | `memory_limit` | `256M` |
| `PHP_UPLOAD_MAX_FILESIZE` | `upload_max_filesize` | `64M` |
| `PHP_POST_MAX_SIZE` | `post_max_size` | `64M`; nginx's body limit follows it |
| `PHP_MAX_EXECUTION_TIME` | `max_execution_time` | `120` |
| `PHP_MAX_INPUT_TIME` | `max_input_time` | `120` |
| `PHP_MAX_INPUT_VARS` | `max_input_vars` | `5000` (Moodle's environment check wants it) |
| `PHP_MAX_FILE_UPLOADS` | `max_file_uploads` | PHP's default, `20` |
| `PHP_DATE_TIMEZONE` | `date.timezone` | `UTC` |
| `PHP_DISPLAY_ERRORS` | `display_errors` | `Off` (`On` in -dev) |
| `PHP_ERROR_REPORTING` | `error_reporting` | PHP's default (`E_ALL`); written unquoted, so `E_ALL & ~E_DEPRECATED` works |
| `PHP_ZEND_ASSERTIONS` | `zend.assertions` | `-1` (`1` in -dev) |
| `PHP_SESSION_COOKIE_SECURE` | `session.cookie_secure` | `1` (`0` in -dev) |
| `PHP_SESSION_COOKIE_SAMESITE` | `session.cookie_samesite` | `Lax` |
| `PHP_SESSION_GC_MAXLIFETIME` | `session.gc_maxlifetime` | PHP's default, `1440` |
| `PHP_SESSION_SAVE_HANDLER` | `session.save_handler` | `files`. Files land in `/tmp` and are lost at every restart: use Redis or the framework's own store, and do so before running more than one replica |
| `PHP_SESSION_SAVE_PATH` | `session.save_path` | PHP's default (the system temp dir, `/tmp`) |
| `PHP_OPCACHE_ENABLE` | `opcache.enable` | `1` |
| `PHP_OPCACHE_ENABLE_CLI` | `opcache.enable_cli` | `0` |
| `PHP_OPCACHE_MEMORY` | `opcache.memory_consumption` | `256` (MiB; Moodle 5.3 has ~60k files). Counts in the FPM auto reserve |
| `PHP_OPCACHE_INTERNED_STRINGS_BUFFER` | `opcache.interned_strings_buffer` | `32` |
| `PHP_OPCACHE_MAX_FILES` | `opcache.max_accelerated_files` | `65407` |
| `PHP_OPCACHE_VALIDATE_TIMESTAMPS` | `opcache.validate_timestamps` | `0`: code is immutable in production (`1` in -dev) |
| `PHP_OPCACHE_REVALIDATE_FREQ` | `opcache.revalidate_freq` | `0` |
| `PHP_OPCACHE_JIT` | `opcache.jit` | `disable` |
| `PHP_OPCACHE_JIT_BUFFER_SIZE` | `opcache.jit_buffer_size` | `0` |
| `PHP_REALPATH_CACHE_SIZE` | `realpath_cache_size` | `4096K` |
| `PHP_REALPATH_CACHE_TTL` | `realpath_cache_ttl` | `600` |
| `PHP_INI_EXTRA` | any | unset. Extra ini lines, written verbatim, one directive per line |
| `PHP_DISABLE_FUNCTIONS` | `disable_functions` in the FPM pool | unset. A comma-separated list, e.g. `exec,shell_exec`. Web requests only: CLI commands (artisan, drush, cron) keep every function |

Other production defaults in `zz-base.ini`: `expose_php=Off`, errors logged to
stderr, `zend.exception_ignore_args=On` (no secrets in stack traces),
`request_order=GP`, `session.use_strict_mode=1`, `session.cookie_httponly=1`,
and `session.upload_progress.enabled=Off` (PHP advisory of 23 Oct 2026).
OPcache JIT is off: it gives little on request-scoped CMS workloads and costs
memory in every worker.

`PHP_VERSION` is set by the image to the full PHP version (e.g. `8.4.27`), with
the same meaning as in the official image. It is information, not a setting.

### PHP-FPM

Rendered into `/tmp/php-base/fpm/zz-runtime.conf`, which the pool includes
last, so it wins over `www.conf`.

| Variable | Pool setting | Default |
|---|---|---|
| `FPM_MAX_CHILDREN` | `pm.max_children` | `auto`: sized from the memory limit, see [Tuning](#tuning). A whole number of at least 1 wins |
| `FPM_WORKER_MEMORY` | — | `64M`: the memory one worker is assumed to need, for `auto` |
| `FPM_PM` | `pm` | `dynamic` |
| `FPM_START_SERVERS` | `pm.start_servers` | a quarter of `max_children`, rounded up, at least 2 |
| `FPM_MIN_SPARE_SERVERS` | `pm.min_spare_servers` | a quarter of `max_children`, at least 1 |
| `FPM_MAX_SPARE_SERVERS` | `pm.max_spare_servers` | half of `max_children`, rounded up, at least 2 |
| `FPM_MAX_REQUESTS` | `pm.max_requests` | `500` |
| `FPM_PROCESS_IDLE_TIMEOUT` | `pm.process_idle_timeout` | `10s` |
| `FPM_REQUEST_TERMINATE_TIMEOUT` | `request_terminate_timeout` | `300s` |
| `FPM_SLOWLOG_TIMEOUT` | `request_slowlog_timeout` | off. E.g. `5s`: traces of slow requests go to the container log |
| `FPM_ACCESS_LOG` | `access.log` | `0`. `1` logs every request with its time and memory, useful while sizing the pool |
| `FPM_POOL_EXTRA` | any | unset. Extra pool lines, verbatim: the escape hatch |

The derived spare-server counts never exceed `max_children`.

### nginx

| Variable | Default | Effect |
|---|---|---|
| `NGINX_WORKER_PROCESSES` | `2` | a number or `auto`. Not `auto` by default: that is one per host CPU, not per CPU the container may use, and each worker holds its own file cache |
| `NGINX_GZIP` | `0` | `1` compresses dynamic responses. Leave it off behind Traefik |
| `NGINX_ACCESS_LOG` | `off` | `main` or `json` logs every request to stdout |
| `NGINX_FASTCGI_READ_TIMEOUT` | `300s` | how long nginx waits for PHP. Keep `max_execution_time` ≤ `FPM_REQUEST_TERMINATE_TIMEOUT` ≤ this ≤ Traefik's read timeout, so the innermost layer gives up first |
| `NGINX_CLIENT_MAX_BODY_SIZE` | PHP's effective `post_max_size` | the request body limit |
| `NGINX_REAL_IP_FROM` | `10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 fc00::/7` | proxies trusted for `X-Forwarded-For`, space-separated. Set it to an empty string to trust nothing. Loopback is not trusted |
| `NGINX_REAL_IP_HEADER` | `X-Forwarded-For` | the header the client IP is read from |
| `NGINX_TRUST_CLOUDFLARE` | `1` | also trust Cloudflare's edge ranges, so a visitor behind Cloudflare → Traefik keeps their own IP. `0` stops at the Cloudflare hop |

### Healthcheck

| Variable | Default | Effect |
|---|---|---|
| `HEALTHCHECK_MODE` | `auto` | `auto`, `fpm`, `http`, `tcp`, `heartbeat` or `none`; see [Healthcheck](#healthcheck) |
| `HEALTHCHECK_URL` | unset | an extra URL for `fpm`, the only one for `http`; must return 2xx/3xx |
| `HEALTHCHECK_PORT` | `8081` for `fpm` | the port for `fpm`; required for `tcp` |
| `HEALTHCHECK_PATH` | `/fpm-ping` | the path for `fpm` |
| `HEALTHCHECK_MAX_AGE` | 3 × the interval + 30 | seconds since the last successful `php-base-every` run, for `heartbeat` |

### Background jobs, hooks, paths

| Variable | Default | Effect |
|---|---|---|
| `SCHEDULER_COMMAND` | unset | web role: run this every `SCHEDULER_INTERVAL` seconds inside the web container |
| `SCHEDULER_INTERVAL` | `60` | seconds, a whole number above 0 |
| `WORKER_COMMAND` | unset | web role: run this continuously inside the web container, restarted when it exits |
| `PHP_BASE_STRICT` | `0` | `1` refuses to start when a hook is not root-owned or is writable by group or others |
| `APP_ROOT` | `/var/www/html` | the app root; the scheduler and worker run in it |
| `XDEBUG_MODE` | `off` (-dev only) | e.g. `debug` or `develop,coverage` turns Xdebug on. On Linux, add `extra_hosts: ["host.docker.internal:host-gateway"]` |

PCOV, also -dev only, turns on with `php -d pcov.enabled=1 …` or
`PHP_INI_EXTRA=pcov.enabled=1`.

A malformed value (a worker count of `08`, an unknown log format, a body
limit nginx can't parse) stops the container at start with one line naming
the variable.

## Tuning

### PHP-FPM workers: `FPM_MAX_CHILDREN=auto`

`auto` gives the workers whatever the memory limit leaves after a reserve:

```
max_children = clamp(floor((L − R) / W), 2, 64)

L  the cgroup memory limit (v2 memory.max, else v1 memory.limit_in_bytes)
W  FPM_WORKER_MEMORY (64M)
R  opcache.memory_consumption + 64 MiB + T
T  the size of /tmp when /tmp is a tmpfs, else 0
```

`T` is in the reserve because uploads, nginx's body buffers and ImageMagick's
cache files live in `/tmp`, and on a tmpfs they are RAM charged to the same
limit. With no memory limit at all, the result is 12. The effective OPcache
size counts, so `PHP_OPCACHE_MEMORY` changes the reserve.

The entrypoint logs the inputs and the result at every start:

```
[entrypoint] fpm: max_children=7 (limit 1024M, worker 64M, reserve 576M)
```

| Memory limit | `/tmp` | Workers |
|---|---|---|
| 1g | tmpfs, `size=256m` (the hardened flags) | (1024 − 576) / 64 = **7** |
| 1g | a volume | (1024 − 320) / 64 = **11** |
| 2g | a volume | (2048 − 320) / 64 = **27** |
| none | anything | **12** |

**`/tmp` must be a sized tmpfs or a volume.** A tmpfs mounted without
`size=` (`--tmpfs /tmp`, or compose's `tmpfs: [/tmp]`) may grow to half the
host's RAM, and that is the size `auto` reserves. Getting more than 2 workers
then takes a memory limit well above half the host's RAM: half the RAM +
OPcache + 64 MiB + 2 workers, about half the RAM + 448 MiB with the defaults.
Below that, `auto` falls back to the minimum of **2**. The log line shows it: a reserve as large as, or
larger than, the limit. Always give the size:

```yaml
tmpfs:
  - /tmp:rw,noexec,nosuid,nodev,size=256m
```

`FPM_WORKER_MEMORY` is an estimate. Measure the real average from
`/fpm-status` (`docker exec app curl -s 127.0.0.1:8081/fpm-status?full`), or
with `FPM_ACCESS_LOG=1`, which logs each request's memory, and set it or
`FPM_MAX_CHILDREN` from that.

### Timeouts and uploads

- PHP `max_execution_time` (120) ≤ `FPM_REQUEST_TERMINATE_TIMEOUT` (300s) ≤
  `NGINX_FASTCGI_READ_TIMEOUT` (300s) ≤ Traefik's read timeout. A long-running
  app such as Moodle raises all of them together (the Moodle example uses
  600 s).
- To raise the upload limit, set `PHP_UPLOAD_MAX_FILESIZE` and
  `PHP_POST_MAX_SIZE`; nginx follows. Then grow the `/tmp` tmpfs to at least
  2 × `post_max_size` + 32 MB and the memory limit with it, or move `/tmp` to
  a volume.

## Commands in the image

| Command | What it does |
|---|---|
| `php-base-web` | the default `CMD`: runs s6 on the scan directory the entrypoint rendered. It refuses to start if the entrypoint was bypassed |
| `php-base-every [--name N] [--no-align] [--once] SECONDS [--] CMD…` | the container-native cron (see [Roles](#roles-one-image-any-command)) |
| `php-base-info` | what this image is: PHP, Alpine and nginx versions, the upstream and base digests, the build date and commit, the extensions. `--short` for one line (logged at every start), `--json` for scripts |
| `php-base-validate` | tests the nginx and php-fpm configuration. At build time it creates a stand-in `/tmp/php-base` for the test and deletes it afterwards, so a root build step leaves no root-owned files behind; inside a running container it tests the live configuration. Use it rather than a bare `nginx -t` |
| `nginx-validate.sh` | the same as `php-base-validate`, kept for v1 Dockerfiles |
| `healthcheck.sh` | the image `HEALTHCHECK` |
