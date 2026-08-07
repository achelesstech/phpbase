# Changelog

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
`apps/moodle5/`), and the four root compose files (replaced by per-app compose
in `apps/*/`).
