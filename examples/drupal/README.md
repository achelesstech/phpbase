# Drupal on php-base

A complete starting point for a Drupal 11 site on
`achelesstech/php-base:8.4`: a multi-stage image, local development, and a
hardened production stack behind Traefik (`examples/traefik`).

| File | What it is |
|---|---|
| `Dockerfile` | `vendor` (Composer and the Drupal scaffold, in the `-dev` base), `build` (autoloader), `production`, `dev` |
| `compose.yml` | local development: target `dev`, source bind-mounted, http://localhost:8080 |
| `compose.prod.yml` | production: `app`, `scheduler`, `migrate` (profile `ops`), `db` (PostgreSQL 18) |
| `.env.example` | every setting, documented |
| `docker/settings.php` | Drupal's `settings.php`, read from the environment (see [Read-only root](#read-only-root)) |
| `.github/workflows/build-app.yml` | build, boot with `compose.prod.yml`, install, assert a real 200, Trivy, push |
| `renovate.json` | keeps both base digests current, plus PostgreSQL |
| `.dockerignore`, `.hadolint.yaml` | build context and lint policy |

Nginx comes from the base: the Dockerfile links the `drupal.conf` preset
(`/etc/nginx/presets/drupal.conf`, docroot `web/`, PHP only through Drupal's
own front controllers). Extra `location` blocks go into
`/etc/nginx/server.d/*.conf` at build time; there is no vhost to maintain.
PHP timeouts come from the base too (`NGINX_FASTCGI_READ_TIMEOUT`,
`FPM_REQUEST_TERMINATE_TIMEOUT`).

## 1. Copy it into the site repository

```bash
SITE=~/code/my-drupal-site           # an existing composer-managed site, or:
# composer create-project drupal/recommended-project:^11 "$SITE"
cd "$SITE" && composer require drush/drush && cd -
cp -r examples/drupal/. "$SITE/"
cd "$SITE"
cp .env.example .env                 # then fill it in (below)
```

The project uses the `drupal/recommended-project` layout (docroot `web/`) and
must require `drush/drush`: the scheduler and the `migrate` one-shot run it,
and the image build stops without it. Commit `composer.lock`.

`docker/settings.php` replaces `web/sites/default/settings.php`: the image
bakes it in, and `compose.yml` mounts it there. Do not commit a
`web/sites/default/settings.php` of your own.

## 2. The two base digests

The Dockerfile starts with two arguments, each pinned by digest to a published
build of the 8.4 line, so the site image builds as copied:

```dockerfile
ARG PHP_BASE_IMAGE=docker.io/achelesstech/php-base:8.4@sha256:…
ARG PHP_BASE_DEV_IMAGE=docker.io/achelesstech/php-base:8.4-dev@sha256:…
```

`:8.4` alone would change the site image whenever the base is rebuilt, and
last week's build could not be reproduced. A tag-only reference still builds
when you need one:
`docker build --build-arg PHP_BASE_IMAGE=docker.io/achelesstech/php-base:8.4 …`.

**Renovate** (`renovate.json`) keeps both digests current in one PR, every
Monday. That PR is the CVE patch path: the base is rebuilt weekly. It never
moves the PHP line (8.4 → 8.5); change both tags by hand for that.

A fresh copy starts on the build this template pins, which may be weeks old:
let Renovate's first PR land before the first deploy, or read the current
digests by hand:

```bash
docker buildx imagetools inspect docker.io/achelesstech/php-base:8.4     --format '{{.Manifest.Digest}}'
docker buildx imagetools inspect docker.io/achelesstech/php-base:8.4-dev --format '{{.Manifest.Digest}}'
```

## 3. Local development

```bash
docker compose up -d --build
docker compose exec app composer install
docker compose exec app vendor/bin/drush site:install standard -y
```

OPcache re-checks file times (`PHP_OPCACHE_VALIDATE_TIMESTAMPS=1`), so edits
show up without a rebuild. Xdebug is loaded but off until you ask for it:
`XDEBUG_MODE=debug docker compose up -d`. Composer is in the `-dev` image
only, which is what the `dev` target and the image's `vendor` stage use; the
production image has none.

Export configuration as you change it, and commit it:
`docker compose exec app vendor/bin/drush config:export -y` writes
`config/sync/`.

## 4. Production

On the VPS, next to a running `examples/traefik` (which creates the `proxy`
network):

```bash
cp .env.example .env                 # APP_DOMAIN, TRAEFIK_ROUTER, TRAEFIK_CERT_RESOLVER, DRUPAL_HASH_SALT, DB_PASSWORD
docker compose -f compose.prod.yml pull                     # or: build
docker compose -f compose.prod.yml up -d
docker compose -f compose.prod.yml exec app vendor/bin/drush site:install standard -y   # first deploy only
docker compose -f compose.prod.yml run --rm migrate         # every deploy after
```

Instead of a fresh install, a site that already has configuration installs
from it: `drush site:install --existing-config -y`.

Database updates run from the one-shot `migrate` service, never from every
container's entrypoint, where they would run concurrently. It runs
`drush updatedb -y`. Once `config/sync/` is committed, change it to
`[vendor/bin/drush, deploy, -y]` (updates, `config:import`, cache rebuild and
deploy hooks, in the right order). Until the site is installed, the
scheduler's `drush cron` fails and logs it; it succeeds from the next minute
on.

| Service | Role | `mem_limit` |
|---|---|---|
| `app` | web: nginx + PHP-FPM; healthy when `/fpm-ping` on the internal `127.0.0.1:8081` answers through PHP-FPM (plus `HEALTHCHECK_URL`, if you set one) | 1g |
| `scheduler` | `php-base-every 60 vendor/bin/drush cron`; healthy while runs keep succeeding | 512m |
| `migrate` | `drush updatedb -y`, profile `ops`, run by hand | 512m |
| `db` | PostgreSQL 18 | — |

Drupal's own `automated_cron` (cron at the end of page requests) is switched
off in `settings.php`: the scheduler already runs it. Backups:
`docker compose -f compose.prod.yml exec db pg_dump -U drupal drupal`, plus the
`drupal-files` and `drupal-private` volumes.

### Choosing the certificate resolver

`TRAEFIK_CERT_RESOLVER` in `.env` picks how Traefik gets the certificate. The
rule depends on where the domain's **DNS** is hosted, not where it was
registered:

| DNS hosted at | `TRAEFIK_CERT_RESOLVER` | How |
|---|---|---|
| Cloudflare | `cloudflare` (the default) | DNS-01 through the Cloudflare API token |
| anywhere else: Namecheap, GoDaddy, a local registrar, your own DNS | `letsencrypt` | HTTP-01 |

For `letsencrypt`, the domain's `A`/`AAAA` record must point straight at the
VPS (no proxy or CDN in front), and port 80 must be open to the internet
before Traefik first sees the router. A domain whose DNS is not on Cloudflare
but left on `cloudflare` never gets a certificate: browsers see a TLS error and
the Traefik log a DNS-01 failure. More in `docs/traefik/labels.md` in the
php-base repository.

`TRAEFIK_ROUTER` names the Traefik router and service. It must be unique on
the host: two stacks with the same name silently merge into one route.

### Host name and client address

`APP_DOMAIN` is also Drupal's only trusted host (`trusted_host_patterns` in
`settings.php`): a request with any other `Host` header gets a 400. There are
no reverse-proxy settings. nginx in the base already sets `REMOTE_ADDR` to the
visitor's address (from the trusted proxy's `X-Forwarded-For`) and `HTTPS`
from `X-Forwarded-Proto`, so Drupal sees the real client and scheme without
trusting any header itself.

### Memory: `mem_limit`, the `/tmp` tmpfs and `FPM_MAX_CHILDREN=auto`

The base sizes the PHP-FPM pool from the container's memory limit
(`FPM_MAX_CHILDREN=auto`, the default):

```
workers = (mem_limit − (OPcache + 64 MiB + /tmp tmpfs size)) / 64 MiB      clamped to 2–64
        = (1024 − (256 + 64 + 256)) / 64 = 7                               for app
```

The `/tmp` tmpfs is RAM, charged to the same limit: uploads in flight and
ImageMagick's cache live there. So `auto` reserves its full size.

- **Always give the tmpfs a `size=`.** Without one, Linux sizes it at half the
  host's RAM, the reserve swallows the limit, and `auto` falls back to 2 workers.
- **Size it for uploads:** at least 2 × `post_max_size` + 32 MB. The defaults
  (64M) fit in 256m. Raising `PHP_POST_MAX_SIZE`? Raise the tmpfs, then
  `mem_limit` by as much again, or the pool shrinks.
- **More workers:** raise `mem_limit`; each 64 MiB adds one. A site with many
  modules may need more than 64 MiB per request: set `FPM_WORKER_MEMORY`
  (and `PHP_MEMORY_LIMIT`) to match, and `auto` divides by that instead.
  `FPM_MAX_CHILDREN` also takes a fixed number. The app container logs its
  choice at start: `fpm: max_children=7 (limit 1024M, worker 64M, reserve 576M)`.

### Read-only root

Every Drupal container runs with `read_only: true`, `cap_drop: [ALL]`,
`no-new-privileges`, a `pids_limit` and a sized `/tmp` tmpfs. The code is
root-owned; PHP cannot change it. What that means for the site:

- **Two writable paths, both volumes:** `public://`
  (`web/sites/default/files`, volume `drupal-files`) and `private://`
  (`/var/www/html/private`, outside the docroot, volume `drupal-private`).
  Twig's compiled templates live under `public://php/`, which nginx never
  executes.
- **`settings.php` comes from `docker/settings.php`** and holds no secrets:
  the database, `hash_salt` and the trusted host come from `.env`. It is
  read-only, and so is `web/sites/default`; the installer accepts that because
  the database settings and `config/sync/` already exist.
- **Modules and themes arrive with a new image**, never through the UI
  (`allow_authorize_operations` is off). `composer require` in development,
  commit `composer.lock`, deploy.

## 5. Registry: keep the site image private

The site image contains your code. Its repository must be **private**.

`build-app.yml` pushes to Docker Hub as `docker.io/achelesstech/drupal-app`.
That name is one variable at the top of `build-app.yml` (`APP_IMAGE`) and of
`compose.prod.yml` (`x-image`); rename it in both, together. Before the first
push:

1. Create the repository on Docker Hub as **private**. Docker Hub's free plan
   allows only one private repository; a second site needs a paid plan or GHCR.
2. Set `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` (a Read & Write access token,
   not the password) as secrets on the site's GitHub repository.

**GHCR (GitHub Container Registry)** is the alternative: any number of private
packages (storage and transfer have free quotas). Use `ghcr.io/<owner>/<app>` as
the image name in both files, log in with
`registry: ghcr.io`, `username: ${{ github.actor }}`,
`password: ${{ secrets.GITHUB_TOKEN }}`, give the job `packages: write`, and
on the VPS `docker login ghcr.io` with a token that has `read:packages`. Check
the package's visibility after the first push.
