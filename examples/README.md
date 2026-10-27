# Examples

Starting points to copy into your own repository. Nothing here is built or
deployed from this repository. Each app example's own `build-app.yml` builds,
boots and scans it once it lives in your repository.

| Example | What it is | Base, stack |
|---|---|---|
| [`laravel/`](laravel/) | a Laravel 13 app: copy it into the app repository, next to your code | `php-base:8.4`; `laravel.conf` preset; app, queue, scheduler; PostgreSQL 18 |
| [`drupal/`](drupal/) | a Drupal 11 site (`drupal/recommended-project`): copy it into the site repository | `php-base:8.4`; `drupal.conf` preset; app, scheduler (`drush cron`); PostgreSQL 18 |
| [`wordpress/`](wordpress/) | a deployment repository: core is downloaded at build; your themes and plugins live here | `php-base:8.4`; `wordpress.conf` preset; app, scheduler (WP-Cron); MariaDB 11.4 |
| [`moodle/`](moodle/) | a deployment repository for Moodle 5.3 LTS: the release is downloaded at build | `php-base:8.4`; `moodle.conf` preset; app, scheduler (cron); PostgreSQL 18 |
| [`traefik/`](traefik/) | the edge proxy for the host: TLS, both certificate resolvers, middlewares, a read-only Docker socket proxy | once per host; every app above sits behind it |
| [`portainer/`](portainer/) | Portainer CE behind Traefik, with no published ports | once per host, optional |

Each directory's README is the full guide. This page covers what they have in
common.

## Copying an app example

```bash
APP=~/code/my-laravel-app
cp -r examples/laravel/. "$APP/"        # the trailing /. copies .env.example, .github/, …
cd "$APP"
cp .env.example .env                    # fill it in; never commit .env
```

Then:

1. **Pin both base images by digest.** The Dockerfile starts with
   `PHP_BASE_IMAGE` (the runtime, for production) and `PHP_BASE_DEV_IMAGE`
   (`-dev`, for the Composer stage and local development). Read the digests
   with

   ```bash
   docker buildx imagetools inspect docker.io/achelesstech/php-base:8.4     --format '{{.Manifest.Digest}}'
   docker buildx imagetools inspect docker.io/achelesstech/php-base:8.4-dev --format '{{.Manifest.Digest}}'
   ```

   `:8.4` alone changes your image whenever the base is rebuilt, and last
   week's build can't be reproduced. The example's `renovate.json` keeps both
   digests current.
2. **Run it locally:** `docker compose up --build` (the `dev` target, on
   http://localhost:8080).
3. **Name the app image** and keep its repository **private**: it contains
   your code or configuration. The name is one variable at the top of
   `build-app.yml` and of `compose.prod.yml`; change both together. Docker
   Hub's free plan has one private repository, and GHCR is the documented
   alternative. Before the first push, set the `DOCKERHUB_USERNAME` and
   `DOCKERHUB_TOKEN` secrets on the app repository.
4. **Deploy behind Traefik** with `compose.prod.yml`, after the Traefik
   example is running on the host. Set `TRAEFIK_CERT_RESOLVER` in `.env` by
   where the domain's DNS is hosted: `cloudflare` for Cloudflare DNS,
   `letsencrypt` for anywhere else
   ([`../docs/reverse-proxy.md`](../docs/reverse-proxy.md#certificates-which-resolver)).

The Traefik and Portainer examples are host-level stacks, not app templates.
Set them up once per host:
[`../docs/traefik/vps-setup.md`](../docs/traefik/vps-setup.md) goes from a
bare VPS to Traefik serving traffic.

## What the app examples share

- **Two bases, one image.** A build stage `FROM` the `-dev` base runs
  `composer install` (Composer is only in `-dev`). The production stage
  `FROM` the runtime base gets root-owned code, and only the framework's
  writable paths belong to `www-data`. A `dev` target `FROM` the `-dev` base,
  with Xdebug off until `XDEBUG_MODE` is set, is what `compose.yml` runs.
- **nginx comes from a preset.** The Dockerfile links the framework's preset
  into `/etc/nginx/conf.d/` and runs `nginx-validate.sh`, so a broken config
  fails the build, not production. There is no vhost to maintain; extra
  `location` blocks go into `/etc/nginx/server.d/`.
- **Hardened production.** `compose.prod.yml` runs every PHP
  service `read_only`, with a sized `/tmp` tmpfs (256 MB; Moodle's `app` uses a
  volume for its 512M uploads), `cap_drop: [ALL]`, `no-new-privileges`, a
  `pids_limit` and a `mem_limit` that `FPM_MAX_CHILDREN=auto` sizes the
  PHP-FPM pool from. There are no `ports:`: Traefik reaches the app on the
  `proxy` network.
- **One image, several roles.** `app` runs the default command (nginx and
  PHP-FPM). Queue workers and the scheduler run the same image with their
  own `command:`; the scheduler uses `php-base-every 60 …`.
- **Health is built in; no `healthcheck:` overrides.** The image's check
  picks its probe by role ([`../docs/image.md`](../docs/image.md#healthcheck)):
  - `app`: PHP-FPM must answer on the internal status listener,
    `127.0.0.1:8081`, plus the app's own page when `HEALTHCHECK_URL` is set
    (Laravel's `/up`, WordPress's `/wp-login.php`);
  - the scheduler: its `php-base-every` heartbeat must be recent;
  - a queue worker: `none`.

  Traefik routes only to containers Docker reports healthy.
- **Migrations (and Moodle's install) are one-shot services** in the `ops` profile,
  run by hand (`docker compose -f compose.prod.yml run --rm migrate`). They
  never run in an entrypoint, where every replica would run them at once.
- **Only real state is a volume:** Laravel `storage/app`, Drupal's public and
  private files, WordPress `wp-content/uploads`, Moodle's moodledata. Code
  always comes from the image, and framework caches are baked into it.

Before going live, read [`../docs/reverse-proxy.md`](../docs/reverse-proxy.md):
Traefik's `trustedIPs`, the keep-alive and timeout chain, and the Cloudflare
settings that break PHP apps.

## Symfony

There is no Symfony example. Start from `laravel/`: the layout is the same
(front controller in `public/`, Composer, optional Node build), and the
`laravel.conf` preset fits. Replace the artisan steps with
`bin/console cache:warmup`.
