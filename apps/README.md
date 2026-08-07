# Application templates

Each directory is a **complete set of files to copy into a real repository**.
They are not built from here.

| Template | Base | Docroot | Kind |
|---|---|---|---|
| `laravel13` | `php-base:8.4` | `public/` | your code — copy into the app repo |
| `laravel11` | `php-base:8.2` | `public/` | your code — ⚠ EOL, migration bridge only |
| `drupal11` | `php-base:8.4` | `web/` | your code — copy into the app repo |
| `moodle52` | `php-base:8.4` | detected | upstream tarball — deployment repo |
| `moodle50` | `php-base:8.4` | detected | upstream tarball — deployment repo |
| `wordpress` | `php-base:8.4` | install root | upstream tarball — deployment repo |

The distinction matters. For Laravel and Drupal the Dockerfile lives next to
your code. For Moodle and WordPress the "app" is someone else's tarball, so the
repo is a *deployment* repo: one per site, holding only the Dockerfile, vhost,
compose and any themes/plugins you actually own.

## Copying one in

```bash
APP=~/code/my-laravel-app
cp -r apps/laravel13/. "$APP/"
cd "$APP"
cp .env.example .env      # then fill it in
docker compose up -d --build
```

Then pin the base by digest:

```bash
docker buildx imagetools inspect ghcr.io/achelesstech/php-base:8.4 \
  --format '{{.Manifest.Digest}}'
```

```dockerfile
ARG BASE_IMAGE=ghcr.io/achelesstech/php-base:8.4@sha256:<that digest>
```

`:8.4` alone means the app image changes silently whenever the base is rebuilt.
`renovate.json` keeps the digest current.

## What every template contains

```
Dockerfile                      multi-stage, plus a dev target with Xdebug
.dockerignore
compose.yml                     local dev, ports published, OPcache revalidating
compose.prod.yml                Traefik-fronted, no published ports
.env.example
docker/vhost.conf               the one static server{} block
docker/entrypoint.d/10-*.sh     runtime init hook
.github/workflows/build-app.yml build, boot, assert a real 200, scan
renovate.json
```

## Conventions all of them follow

**The vhost is a static file**, validated with `nginx-validate.sh` at build
time — so a broken vhost fails the build, not production. Use that wrapper, not
a bare `nginx -t`: `nginx -t` creates a pid file and opens its default error log
as side effects, and when the build runs as root those get baked in root-owned
and nginx can never start as www-data.

**Framework caches are baked into the image**, not written at startup. Writing
them at boot means app/queue/scheduler race over the same files, and a
persistent cache volume shadows the image copy with a stale one.

**Migrations, upgrades and installs are one-shot `ops` services**, never
entrypoint side effects that every replica runs at once.

```bash
docker compose -f compose.prod.yml --profile ops run --rm migrate   # Laravel
docker compose -f compose.prod.yml --profile ops run --rm drush updatedb -y
docker compose -f compose.prod.yml --profile ops run --rm install   # Moodle / WP
docker compose -f compose.prod.yml --profile ops run --rm upgrade   # Moodle
```

**Worker containers override the healthcheck.** They run no nginx, so the
image's `/fpm-ping` check can never pass.

**Only real state is a volume.** Laravel `storage/app`, Drupal
`sites/default/files`, Moodle `/var/moodledata`, WordPress
`wp-content/uploads`. Code always comes from the image.

## Reverse proxy

All of these are backends behind Traefik, usually with Cloudflare in front.
Read [`../docs/reverse-proxy.md`](../docs/reverse-proxy.md) before going live —
it covers the Traefik `trustedIPs` setting that keeps X-Forwarded-For
trustworthy, and the five Cloudflare behaviours that break PHP apps (SSL mode,
the 100 MB upload cap, the 100 s timeout, cache rules, real-IP headers).

## Moodle specifics

**Version differences are detected, not assumed.** Moodle's `public/`
restructure and its Routing Engine (`r.php`) arrived in different releases, and
hardcoding either into a Dockerfile guarantees it goes stale. `select-vhost.sh`
inspects the extracted tarball at build time, installs `vhost-public.conf` or
`vhost-legacy.conf`, and writes what it found to `/etc/moodle-layout`. The build
log prints it.

**Moving to 5.3 LTS in October:** copy `moodle52` to `moodle53`, change
`MOODLE_BRANCH` to `503`. Nothing else should need editing. Verify with the
build log and the doctor.

**When something is wrong**, run the diagnostic rather than guessing:

```bash
docker compose exec app moodle-doctor.sh
```

It checks the specific ways Moodle-on-nginx fails — the ones Apache hides
because `.htaccess` and `mod_php` handle pathinfo and X-Sendfile differently:

- nginx docroot vs the actual Moodle layout
- `wwwroot` trailing slash, and `sslproxy` vs an `https://` wwwroot
  (mismatch = infinite redirect loop, with no error message)
- dataroot inside the web root, or not writable
- the `/dataroot/` X-Accel-Redirect location: present, `internal`, trailing
  slash on the alias, and **`^~` rather than a plain prefix** — without `^~` the
  internal redirect re-matches and the static-asset regex wins, so every CSS and
  image served through `pluginfile.php` 404s. That is what "the theme is
  broken" almost always means.
- live slashargument requests (`/theme/styles.php/...`,
  `/lib/requirejs.php/1/all.js`) actually reaching PHP
- `r.php` present but `$CFG->routerconfigured` not set
- whether cron is running anywhere

## WordPress specifics

The `wp-content/uploads` PHP deny rule in the vhost is **mandatory**, not
optional hardening — arbitrary upload followed by direct execution is the most
exploited path in the WordPress ecosystem. It is verified in CI by planting a
`shell.php` and asserting a 404.

Plugins and themes should be committed to the repo, not installed through the
admin UI: the container filesystem is not the source of truth and anything
installed there is lost on the next deploy. `DISALLOW_FILE_MODS` is set unless
you opt out with `WORDPRESS_ALLOW_UPDATES=true`.

## Symfony

No template. Start from `laravel13` — the layout is the same (front controller
in `public/`, composer, optional Node build). Replace the artisan calls in the
entrypoint hook with `bin/console cache:warmup`.
