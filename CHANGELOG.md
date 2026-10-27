# Changelog

## v2: rebuilt within hours, a smaller and harder runtime, Traefik-first defaults

The image is still `docker.io/achelesstech/php-base`, but app images built on
v1 need changes before they work. Every change and what to do about it is in
[`docs/migrating-from-v1.md`](docs/migrating-from-v1.md).

### Breaking changes

- **supervisord is gone.** The default CMD is `php-base-web`: s6 supervises
  nginx and PHP-FPM. `/etc/supervisor` and Python are gone. A command that
  still runs `supervisord` exits at start with a message pointing at the
  migration guide. Extra programs become separate containers, or
  `WORKER_COMMAND` / `SCHEDULER_COMMAND`.
- **PHP-FPM listens on `/tmp/php-base/php-fpm.sock`**, mode 0660, and
  nothing listens on 9000. Own vhosts use `fastcgi_pass php_fpm;` or include
  `/etc/nginx/php-base/fastcgi-php.conf`.
- **`/fpm-ping`, `/fpm-status` and `/nginx-status` are only on
  `127.0.0.1:8081`.** A vhost defines no status paths; delete v1's own
  `location = /fpm-ping` blocks.
  The healthcheck's default port for the `fpm` mode is 8081.
- **Composer, git, Info-ZIP unzip (busybox's stays), patch, openssh-client, PHP sources and headers,
  `phpize`, PEAR/PECL and the `docker-php-ext-*` helpers ship only in
  `-dev`.** `composer install` moves to a `-dev` build stage.
- **No `php.ini-production` or `php.ini-development`.** The runtime is a
  clean Alpine with PHP's runtime files copied in, so the official image's
  `mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"` fails the
  build. `zz-base.ini` already carries the production values.
- **`$HOME` (`/home/www-data`) is a symlink to `/tmp/php-base/home`**,
  recreated empty at every start. It doesn't exist during `docker build`.
- **Runtime config moved to `/tmp/php-base/`** and is wiped at every start.
  `/etc/php-runtime.d/` and `php-fpm.d/zz-runtime.conf` are gone;
  `/etc/php-base-release` is now `/etc/php-base/release`.
- **New tags.** `X.Y`, `X.Y.Z`, `X.Y.Z-YYYYMMDD` (`.N` for a second build
  that day), `latest`, and a `-dev` twin of each. v1's `X.Y-<run number>`
  tags are not continued, and there
  are no `X.Y-alpineA.B` tags: a tag tied to one Alpine release stops
  getting PHP updates.
- **Behaviour you will notice**, each with a variable to restore it:
  - the nginx access log is off (`NGINX_ACCESS_LOG=main`), and so is the FPM
    access log (`FPM_ACCESS_LOG=1`);
  - nginx no longer compresses dynamic responses (`NGINX_GZIP=1`);
  - the PHP-FPM pool is sized from the memory limit (`FPM_MAX_CHILDREN=auto`,
    7 workers at 1g with a 256 MB `/tmp` tmpfs; v1 had a fixed 12);
  - `client_max_body_size` follows `post_max_size` instead of a fixed 100m.
- **Worker and scheduler `pgrep` healthchecks should go.** The image's check
  is role-aware: `fpm` for the web role, `heartbeat` for `php-base-every`,
  `none` for any other command.

### Security

- **PHP2Shell (CVE-2026-109618/109619).** v1 pinned an `alpine3.21` upstream
  tag that stopped receiving PHP releases in November 2025, so `:8.4` was
  still on PHP 8.4.15. The build now resolves the floating
  `php:<line>-fpm-alpine` to a digest on every run, and fails a line whose
  PHP is behind a php.net release more than 3 days old.
- **Rebuilt within about 6 hours** of a new PHP image, a new `alpine:<minor>`
  digest, or a pending Alpine package upgrade in the published image
  (`watch-upstream.yml`), and weekly regardless. Every build runs
  `apk upgrade` on a cache-busted layer.
- **A clean Alpine runtime.** The runtime has no compiler inputs, no PHP
  sources, no PEAR, no Composer, no Python, no `php-cgi` or `phpdbg`, and no
  setuid or setgid file. The build fails if one appears.
- **PHP-FPM on a Unix socket only.** v1's TCP listener was already
  loopback-only; v2 has no FastCGI port at all, so none can be
  misconfigured or published (a FastCGI client can set `PHP_VALUE`).
- **Status pages on a loopback-only listener.** v1's `allow 127.0.0.1` on
  the public port could be passed by any container sending
  `X-Forwarded-For: 127.0.0.1`.
- **An ImageMagick policy:** an allowlist of raster formats, no delegates,
  and a memory cap per operation.
- **Hook checks.** A hook that isn't root-owned, or is writable by group or
  others, logs a warning; `PHP_BASE_STRICT=1` refuses to start. The check
  looks at ownership and mode, so a `www-data`-owned 0555 hook is caught.
- Optional `PHP_DISABLE_FUNCTIONS`, applied to the FPM pool only.
- Tested under `--read-only`, a `noexec` `/tmp` tmpfs, `--cap-drop ALL`,
  `no-new-privileges` and a PID limit
  ([`docs/security.md`](docs/security.md)).
- `session.upload_progress.enabled = Off`, per the PHP advisory of
  2026-10-23, and production engine defaults the official image lacks:
  `zend.assertions=-1`, `zend.exception_ignore_args=On`,
  `request_order=GP`, `output_buffering=4096`.

### Image

- PHP 8.2, 8.3, 8.4 and 8.5, all built from `versions.json`, on native amd64
  and arm64. 8.6 is added when it is released: its release candidates do not
  yet build the PECL extensions.
- A `-dev` variant: Composer 2, git, Xdebug and PCOV (both off), PHP sources
  and `phpize`, so an app can compile its own extension.
- Extensions added: gmp, sockets, igbinary, memcached and uploadprogress.
  phpredis supports igbinary, zstd and lz4. ImageMagick has its HEIC, WebP
  and JPEG coders. PECL extensions are built from pinned release tarballs
  (igbinary 3.2.17RC1, the only release that builds on PHP 8.5).
- `php-base-every`: an aligned, non-overlapping periodic runner with a
  heartbeat, the container-native cron.
- `php-base-info [--short|--json]`, and `php-base-validate` to test the nginx
  and FPM config at build time without leaving root-owned files behind.
- nginx presets for Laravel, Drupal, WordPress and Moodle (`public/` and
  legacy layouts), shared snippets, and a `server.d/` extension point.
- **Traefik-friendly nginx:** `keepalive_timeout 120s` (longer than
  Traefik's 90s backend idle timeout), `keepalive_requests 10000`,
  `gzip_static`, `open_file_cache`, `SERVER_PORT` from `X-Forwarded-Port`,
  `NGINX_FASTCGI_READ_TIMEOUT`, and two workers by default.
- `HEALTHCHECK --start-interval=2s`, so Traefik routes a new container within
  seconds (Docker 25+).
- Labels name the Alpine base and the upstream PHP image by digest.

### Fixes

- `/home/www-data` was left owned by the deleted uid 82: the real cause of
  the npm EACCES both Laravel apps worked around.
- `FPM_SLOWLOG_TIMEOUT` made php-fpm refuse to start, because no `slowlog`
  path was set.
- Env-rendered ini values containing `?`, `&` or `=` broke the ini parser,
  which cut a Redis `session.save_path` short and dropped every later
  override.
- Entrypoint logging moved to stderr. Before, CLI output piped from
  `docker run …` started with `[entrypoint]` lines.
- Behind Cloudflare, nginx now records the visitor's IP instead of
  Cloudflare's edge address (the Cloudflare ranges are committed and trusted
  by default).
- File modes are set explicitly instead of inheriting the build host's umask.

### CI

- Images are pushed by digest, pulled back and tested from that digest, then
  tagged. Publishing is per PHP line, so one failing line never blocks the
  others.
- Every build runs the runtime suite under the hardened flags, the `-dev`
  suite, a size ceiling per line, real Laravel, Drupal, WordPress and Moodle
  installs, and Trivy.
- cosign keyless signatures, an SBOM and provenance (`mode=max`). Actions are
  pinned by SHA. A failing scheduled run opens a GitHub issue.
- `lint.yml` runs `scripts/lint.sh` (also `make lint`) on every push and pull
  request: hadolint, ShellCheck, actionlint, `docker compose config` for every
  example, the Traefik config check, the link check and the
  `test/scripts/*.test.sh` unit tests.
- The base workflows need one secret, `DOCKERHUB_TOKEN`, and log in as
  `achelesstech`. A `DOCKERHUB_USERNAME` secret would make GitHub withhold the
  build matrix, which names the image.
- Setup, the watcher and Renovate: [`docs/publishing.md`](docs/publishing.md).

### Examples and docs

- `examples/` holds the Laravel 13, Drupal 11, WordPress and Moodle 5.3 app
  templates, the Traefik edge proxy (two resolvers: `cloudflare` DNS-01 and
  `letsencrypt` HTTP-01, cert-expiry checks, an explicit 90s backend idle
  timeout, a read-only Docker socket proxy) and Portainer
  ([`examples/README.md`](examples/README.md)).
- New docs: [`docs/image.md`](docs/image.md),
  [`docs/security.md`](docs/security.md),
  [`docs/publishing.md`](docs/publishing.md),
  [`docs/migrating-from-v1.md`](docs/migrating-from-v1.md), and a rewritten
  [`docs/reverse-proxy.md`](docs/reverse-proxy.md).

## Registry moved to Docker Hub; CI lint and action versions fixed

### Registry

- **GHCR → Docker Hub.** Everything now publishes to and pulls from
  `docker.io/achelesstech/*`: the base workflow, all six app workflows,
  `Makefile`, every `compose.prod.yml`, every `ARG BASE_IMAGE`, the Renovate
  `matchPackageNames`, and the docs.
- **Auth is now `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`** instead of the
  automatic `GITHUB_TOKEN`. These are real secrets that must be set on each
  repository before the first push; the `packages: write` permission is gone
  because nothing writes to GitHub Packages any more.
- **App workflows hardcode their image name** (`achelesstech/<app>-app`) rather
  than deriving it from `${{ github.repository }}`. Docker Hub repository names
  are independent of GitHub repository names, and the derived form would have
  silently pushed somewhere other than what `compose.prod.yml` pulls if either
  were renamed.
- **Layer cache moved from registry to `type=gha`.** Registry cache stored a
  `*-buildcache` tag next to the real tags, which on Docker Hub means a visible
  junk tag in the repository listing and cache traffic counted against pull
  rate limits. `make push` lost its `--cache-from`/`--cache-to` for the same
  reason: the tag it referenced no longer exists.

### CI

- **`actions/checkout@v4` → `@v5`** in all seven workflows. v4 targets Node 20,
  which GitHub has deprecated and is already force-running on Node 24.
- **hadolint DL3018 and SC2086 resolved via `.hadolint.yaml`**, added at the
  repo root and to every app template. DL3018 ("pin apk versions") is refused
  deliberately: the weekly rebuild exists to pick up Alpine patch releases, and
  Alpine garbage-collects superseded versions from its repos within weeks, so
  pinning would both freeze CVEs and eventually break the build. Reproducibility
  comes from pinning the base image *by digest*, which the app repos do.
  SC2086 fires on `apk add $PHPIZE_DEPS`, which must word-split. DL3066 is
  ignored too (`USER www-data` is uid 1000, asserted at build time).
- **`make lint` now passes the same config CI uses,** so a green local lint
  means a green CI lint. It previously ran bare `hadolint` and disagreed.
- **`HEALTHCHECK` is a single line.** hadolint anchors an inline
  `# hadolint ignore=` to an instruction's first line, so a wrapped HEALTHCHECK
  could not be exempted from DL3025.

## Restructure — one boring base + per-app templates

Replaces the previous single 509-line Dockerfile with 42 build args that
produced seven differently-named "base" images.

### Architecture

- **One image per PHP version.** `php-base:8.4`, `php-base:8.2`. No
  `laravel-nginx-base` / `drupal-nginx-base` / `moodle-nginx-base` — those were
  the same Dockerfile with different `--build-arg`, shared no layers, and named
  a platform while containing none of it.
- **42 build args → 4** (`PHP_VERSION`, `ALPINE_VERSION`, `USER_ID`,
  `GROUP_ID`). The extension set is a fixed union; there are no `INSTALL_*`
  toggles. This makes the dead-toggle and ARG-doesn't-cross-`FROM` bug classes
  structurally impossible.
- **Boundary rule.** Compiled PHP extensions (slow, need a compiler) live in the
  base. OS packages (`ghostscript`, `graphviz`, DB clients — seconds to install,
  no compiler) move to the application image.
- **`NGINX_PROFILE` and the runtime vhost renderer are gone.** Each app ships one
  static `server{}` block, validated by `nginx -t` at build time. The base
  provides the `http{}` block only.
- **All config moved from `RUN cat <<EOF` heredocs into real files** under
  `rootfs/`. This is what made the two build failures and the invalid-PHP bug
  below possible in the first place.
- **`apps/`** holds copy-in templates for Laravel 11/13, Drupal 11 and Moodle 5,
  each with Dockerfile, vhost, hooks, dev + prod compose, CI and Renovate config.

### Fatal bugs fixed

1. **`Dockerfile.wordpress` and `Dockerfile.symfony` could not build.** A
   `chmod` line after a heredoc terminator was parsed as a Dockerfile
   instruction (`unknown instruction: CHMOD`). Neither had ever been built.
   Both templates removed rather than carried forward unverified.
2. **Moodle Redis sessions produced invalid PHP.** `\\\$CFG` inside an unquoted
   heredoc nested in a quoted heredoc nested in `RUN cat` collapsed to a literal
   `\$CFG`, a parse error that took the site down the moment
   `MOODLE_SESSION_HANDLER=redis` was set. Config generation is now a standalone
   script with one level of quoting, and the generated file is `php -l`-checked
   before the container proceeds.
3. **`USER_ID`/`GROUP_ID` were silently ignored.** busybox `deluser` removes the
   user but not the group, so `addgroup -g 1000` failed; with no `set -e` the
   failure was swallowed and containers ran as uid 1000 / **gid 82**. Now
   `delgroup` too, `set -eux`, and the ids are asserted at build time.
4. **The healthcheck could not detect a dead PHP-FPM.** It curled a static nginx
   `return 200`, so a container with dead FPM reported healthy and 502'd every
   request. Now `/fpm-ping`, which goes through FastCGI.
5. **A dead daemon left the container running.** `autorestart = unexpected` plus
   supervisord surviving its children meant a FATAL program was never noticed.
   Now `autorestart = true` plus an event listener that shuts the container down
   on `PROCESS_STATE_FATAL`.
6. **`docker-compose-moodle.yml` ran the base image**, which contains no Moodle.

### Found and fixed while rewriting

7. **Build-time `nginx -t` poisoned the image.** Running it as root created a
   root-owned `/tmp/nginx.pid` and a root-owned
   `/var/log/nginx/error.log`. The former made **nginx fail to start in every
   container** (`/tmp` is sticky, so www-data could not overwrite it); the
   latter caused a permission alert on every start. Both are now handled by
   `nginx-validate.sh` (`-e /dev/stderr` + pid cleanup), with regression guards
   in the test suite. Pid files also moved out of world-writable `/tmp`.

### Security

8. `/usr/local/etc/php/conf.d` stays root-owned. It was chowned to www-data so
   the entrypoint could toggle Xdebug — which let a compromised PHP worker
   persist an `auto_prepend_file` across restarts. Runtime overrides now go to a
   separate directory via `PHP_INI_SCAN_DIR`; Xdebug/PCOV moved to a `dev` build
   stage in the app repos.
9. **Supervisor control socket removed.** It was owned by www-data, the same uid
   FPM workers run as, giving an RCE a process-spawning and persistence channel.
   Nothing needed `supervisorctl`.
10. `fastcgi_param HTTPS $fcgi_https if_not_empty` in every vhost. Without
    `if_not_empty` nginx sends `HTTPS=""` on plain HTTP, so `$_SERVER['HTTPS']`
    is set-but-empty and code testing `isset()` emits `https://` URLs over
    `http://`.
11. **Drupal PHP execution is an explicit entrypoint allowlist.** The previous
    `set $script_path …; if (!-f $script_path)` guard did not work: `set`/`if`
    run in nginx's rewrite phase but `fastcgi_split_path_info` runs in the
    content phase, so `/update.php/selection` 404'd — the exact case it claimed
    to fix. The allowlist sidesteps the phase ordering and makes any uploaded
    `.php` inert.
12. Security headers are set per-vhost, not at `http{}` level. nginx
    `add_header` inheritance is replace-not-merge, so any location setting
    `Cache-Control` silently dropped all inherited headers.
13. WordPress's unguarded `chown -R` under `set -e` (which aborted startup on a
    foreign-uid bind mount) is gone with the template.

### Operational

14. **nginx logs to stdout/stderr.** They went to `/var/log/nginx/*.log` —
    invisible to `docker logs` and growing unrotated in the writable layer.
15. **FPM pool sizing is runtime env**, not build args. It is the most
    deployment-specific setting in the image and was the least changeable.
16. **Framework caches are baked into the image.** Laravel's `config:cache` etc.
    ran at container start against a `bootstrap/cache` volume shared by app,
    queue and scheduler — four containers racing over the same files, and a
    stale cache surviving every deploy. The volume is gone.
17. **Migrations/upgrades are one-shot `ops` profile services**, not entrypoint
    side effects that every replica runs concurrently.
18. **Moodle cron is a real script** with a fixed period (the old `sleep 60`
    after the run made a 5-minute cron fire every 6 and drift), and its output
    goes to the container log instead of `/dev/null`.
19. **Moodle first-install and upgrade paths added.** There was previously no
    documented way to run `install_database.php`.
20. `graceful stopsignal = QUIT` on both daemons, nginx stopped first so it
    drains before FPM.
21. OPcache JIT off by default; `enable_file_override` off; extensions already
    built into `php:*-fpm-alpine` (mbstring, curl, xml, dom, sodium) no longer
    recompiled.
22. Dead `INSTALL_PSPELL` toggle removed — it was declared, threaded through
    both stages and documented, but never installed anything.
23. Duplicate `moodle.conf (1).tpl` removed (byte-identical, and it was being
    copied into the image).

### Reverse proxy (Traefik + Cloudflare)

24. **`REMOTE_ADDR` was the proxy, not the client.** nginx had no `real_ip`
    configuration, so every request appeared to originate from Traefik's
    container IP. That silently disables Moodle login throttling, Drupal flood
    control, Laravel rate limiting, IP bans and all access logging. Now
    `set_real_ip_from` on RFC1918/ULA with `real_ip_recursive on`, which also
    handles the Cloudflare → Traefik → nginx chain. Loopback is deliberately
    untrusted so the `/fpm-ping` ACL cannot be bypassed with a forged header.
25. `docs/reverse-proxy.md` added: Traefik `forwardedHeaders.trustedIPs`
    (without it, XFF is forgeable and every IP-based control is bypassable),
    Cloudflare SSL mode, the 100 MB upload cap that silently 413s Moodle course
    backups, the 100 s timeout behind long upgrades, cache-rule cookie
    bypasses, and per-app trusted-proxy settings.

### Moodle

26. **Split into per-version templates** (`moodle50`, `moodle52`) and the
    docroot layout is now **detected at build time** rather than hardcoded.
    `select-vhost.sh` inspects the extracted tarball, installs
    `vhost-public.conf` or `vhost-legacy.conf`, warns on a public/ layout with
    no `r.php`, and records the result in `/etc/moodle-layout`. Moving to 5.3
    LTS is a one-line `MOODLE_BRANCH` change.
27. **`moodle-doctor.sh` added** — checks the specific ways Moodle-on-nginx
    fails: docroot mismatch, `sslproxy` vs an https wwwroot, dataroot placement
    and writability, and the `/dataroot/` location's `^~`, `internal` and
    trailing-slash alias, plus live slashargument requests. Verified to catch a
    deliberately broken `^~` (reproduced: the CSS 404s without it).

### WordPress

28. **Template restored and verified.** The old one had never built. The vhost
    now carries the mandatory `wp-content/uploads` PHP deny rule the previous
    generic vhost lacked; CI plants a `shell.php` and asserts a 404.
    `wp-config.php` generation is guarded, salts are shuffled once rather than
    on every boot (which would log everyone out), and `WP_HOME`/`WP_SITEURL`
    are set from `WORDPRESS_URL` to prevent the classic redirect loop.

### Testing

`make test` builds a fixture application on the base, boots it, and asserts 23
behaviours — that PHP executes through FastCGI, that uid/gid really are
1000:1000, that runtime overrides land, that `conf.d` is not writable, that no
foreign-owned files are baked in, and that killing PHP-FPM brings the container
down. The previous smoke test booted an application-less image and asserted that
a static nginx response answered; it could not fail.

CI additionally runs hadolint and Trivy, and rebuilds weekly so Alpine and PHP
patch releases land without anyone remembering.

### Verified

Both `php-base:8.4` and `php-base:8.2` build and pass all 23 checks. All eight
app-template vhosts pass `nginx -t`. Moodle `config.php` generation passes
`php -l` with and without Redis sessions.

End to end against real upstream sources:
* **Moodle 5.2** — image builds, layout detection reports `public` + `r.php`,
  `install_database.php` completes, container reaches healthy, `moodle-doctor.sh`
  reports 17 passed / 0 failures, and it correctly flags a deliberately broken
  `^~ /dataroot/`.
* **WordPress** — image builds, `wp-config.php` and unique salts generated,
  container healthy, `GET /` returns 302 to the installer, and a planted
  `wp-content/uploads/shell.php` returns 404 without executing.

### Not carried forward

`Dockerfile.symfony` (never built — see bug 1; start from `laravel13` instead),
`Dockerfile.moodle` (superseded by `Dockerfile.moodle-new`, which is now
`apps/moodle50/` and `apps/moodle52/`), and the four root compose files
(replaced by per-app compose in `apps/*/`).

---

## Added — `traefik/`

A complete edge-proxy deployment: `compose.yml`, static and dynamic config,
`Makefile`, three operational scripts, and three documents
(`README.md`, `STATIC-CONFIG.md` property-by-property, `LABELS.md` for app
repos). It is **not** part of the image and nothing here depends on it; it
lives in this repo temporarily so the proxy and the backends it fronts can be
reviewed together, and will move to its own repository.

Reviewed against the existing production config; findings and fixes are in
`traefik/AUDIT.md`. The ones that were silently wrong rather than broken:

- `rateLimit` `ipStrategy.depth: 2` yielded an **empty** source (the header has
  one entry behind Cloudflare), so all three "per-IP" limits were a single
  global bucket.
- `trustedIPs` listed Cloudflare's IPv4 ranges and none of the IPv6 ones. Over
  IPv6 the edge is untrusted, Traefik overwrites `X-Forwarded-For`, and every
  backend sees Cloudflare as the client — the exact failure bug 24 fixed in
  nginx, reintroduced one hop upstream.
- `accessControlAllowOriginList: "https://*.example.com"` is an exact-string
  match and matched nothing; wildcards need the `…Regex` variant.
- `ipAllowList` with no `ipStrategy` checks the TCP peer, which behind
  Cloudflare is never RFC1918 — `chain-admin` returned 403 to everyone.
- No `respondingTimeouts`, so `websecure` used the 60s default `readTimeout`,
  which bounds the whole request **body**. Large Moodle uploads died as dead
  connections with nothing in the PHP log.
- `ACME_EMAIL` was passed in as an environment variable; Traefik does not
  expand `${VAR}` in static config and nothing read it.

Also: the raw Docker socket replaced with a POST-refusing socket proxy on an
internal network, the Cloudflare token moved from an env var to a file secret,
the CSP and `X-Robots-Tag: none` taken out of the default middleware chain
(they break CMS editors and de-index public sites respectively), and logs moved
from files inside the container to stdout.
