# Laravel on php-base

A complete starting point for a Laravel 13 application on
`achelesstech/php-base:8.4`: a multi-stage image, local development, and a
hardened production stack behind Traefik (`examples/traefik`).

| File | What it is |
|---|---|
| `Dockerfile` | `vendor` (Composer, in the `-dev` base), `assets` (Node, Vite), `build` (autoloader, caches), `production`, `dev` |
| `compose.yml` | local development: target `dev`, source bind-mounted, http://localhost:8080 |
| `compose.prod.yml` | production: `app`, `queue`, `scheduler`, `migrate` (profile `ops`), `db` (PostgreSQL 18) |
| `.env.example` | every setting, documented |
| `docker/entrypoint.d/10-laravel-views.sh` | seeds Blade's compiled views into `/tmp` at start (see [Read-only root](#read-only-root)) |
| `.github/workflows/build-app.yml` | build, boot with `compose.prod.yml`, assert a real 200, Trivy, push |
| `renovate.json` | keeps both base digests current, plus PostgreSQL and Node |
| `.dockerignore`, `.hadolint.yaml` | build context and lint policy |

Nginx comes from the base: the Dockerfile links the `laravel.conf` preset
(`/etc/nginx/presets/laravel.conf`). Extra `location` blocks go into
`/etc/nginx/server.d/*.conf` at build time; there is no vhost to maintain.

## 1. Copy it into the app repository

```bash
APP=~/code/my-laravel-app            # an existing Laravel 13 app, or: composer create-project laravel/laravel:^13.0 "$APP"
cp -r examples/laravel/. "$APP/"
cd "$APP"
cp .env.example .env                 # then fill it in (below)
```

This replaces Laravel's own `.env.example` with this one, which holds the
settings the containers need. Commit `package-lock.json`: without it the image
build falls back to `npm install` and the assets are not reproducible.

For Laravel 12, change one constraint: `laravel/laravel:^12.0` (or
`laravel/framework:^12.0` in an existing app). Nothing else here differs.

## 2. Pin the two base digests

The Dockerfile starts with two arguments, each pinned by digest:

```dockerfile
ARG PHP_BASE_IMAGE=docker.io/achelesstech/php-base:8.4@sha256:<runtime>
ARG PHP_BASE_DEV_IMAGE=docker.io/achelesstech/php-base:8.4-dev@sha256:<dev>
```

Fill in the current digests:

```bash
docker buildx imagetools inspect docker.io/achelesstech/php-base:8.4     --format '{{.Manifest.Digest}}'
docker buildx imagetools inspect docker.io/achelesstech/php-base:8.4-dev --format '{{.Manifest.Digest}}'
```

The image builds only once both are filled in. `:8.4` alone would change the
app image whenever the base is rebuilt, and last week's build could not be
reproduced. A tag-only reference still builds when you need one:
`docker build --build-arg PHP_BASE_IMAGE=docker.io/achelesstech/php-base:8.4 …`.

**Renovate** (`renovate.json`) then keeps both digests current in one PR, every
Monday. That PR is the CVE patch path: the base is rebuilt weekly. It never
moves the PHP line (8.4 → 8.5); change both tags by hand for that.

## 3. Local development

```bash
docker compose up -d --build
docker compose exec app composer install
docker compose exec app php artisan migrate
npm install && npm run dev           # Vite on the host
```

OPcache re-checks file times (`PHP_OPCACHE_VALIDATE_TIMESTAMPS=1`), so edits
show up without a rebuild. Xdebug is loaded but off until you ask for it:
`XDEBUG_MODE=debug docker compose up -d`.

## 4. Production

On the VPS, next to a running `examples/traefik` (which creates the `proxy`
network):

```bash
cp .env.example .env                 # APP_DOMAIN, TRAEFIK_ROUTER, TRAEFIK_CERT_RESOLVER, APP_KEY, DB_PASSWORD
docker compose -f compose.prod.yml pull                     # or: build
docker compose -f compose.prod.yml up -d db
docker compose -f compose.prod.yml run --rm migrate         # first deploy, and every deploy after
docker compose -f compose.prod.yml up -d
```

Migrations run from the one-shot `migrate` service, never from every
container's entrypoint, where they would run concurrently. If `queue` starts
before the first migration, it exits (no `cache` table yet) and Docker keeps
restarting it until `migrate` has run.

| Service | Role | `mem_limit` |
|---|---|---|
| `app` | web: nginx + PHP-FPM; healthy when `/fpm-ping` on the internal `127.0.0.1:8081` answers through PHP-FPM and `HEALTHCHECK_URL` (Laravel's `/up`) returns 2xx/3xx | 1g |
| `queue` | `php artisan queue:work --max-time=3600`; exits hourly on purpose, `restart:` brings it back | 512m |
| `scheduler` | `php-base-every 60 php artisan schedule:run`; healthy while runs keep succeeding | 512m |
| `migrate` | `php artisan migrate --force`, profile `ops`, run by hand | 512m |
| `db` | PostgreSQL 18 | — |

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
- **More workers:** raise `mem_limit`; each 64 MiB adds one. `FPM_MAX_CHILDREN`
  also takes a fixed number. The app container logs its choice at start:
  `fpm: max_children=7 (limit 1024M, worker 64M, reserve 576M)`.

### Read-only root

Every Laravel container runs with `read_only: true`, `cap_drop: [ALL]`,
`no-new-privileges`, a `pids_limit` and a sized `/tmp` tmpfs. The code is
root-owned; PHP cannot change it. What that means for the app:

- **`storage/app` is the one writable path** (the `app-storage` volume): uploads
  and other files. `storage/framework` and `bootstrap/cache` are read-only.
- **Sessions, cache and queue use the database** (or Redis), not files.
- **Logs go to stderr** (`LOG_CHANNEL=stderr`): `docker compose logs app`.
- **Framework caches are baked into the image** at build: `event:cache`,
  `route:cache`, `view:cache`, the optimized autoloader and `storage:link`.
  `config:cache` is not, because it would freeze the build's empty environment;
  configuration comes from `.env` at runtime. Read `env()` only inside
  `config/*.php`.
- **Blade's compiled views** go to `VIEW_COMPILED_PATH=/tmp/laravel/views`,
  seeded at start with the views compiled at build. Views compiled at runtime
  (the `/up` page, error pages, mail templates) go there too.

## 5. Registry: keep the app image private

The app image contains your code. Its repository must be **private**.

`build-app.yml` pushes to Docker Hub as `docker.io/achelesstech/laravel-app`.
That name is one variable at the top of `build-app.yml` (`APP_IMAGE`) and of
`compose.prod.yml` (`x-image`); rename it in both, together. Before the first
push:

1. Create the repository on Docker Hub as **private**. Docker Hub's free plan
   allows only one private repository; a second app needs a paid plan or GHCR.
2. Set `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` (a Read & Write access token,
   not the password) as secrets on the app's GitHub repository.

**GHCR (GitHub Container Registry)** is the alternative: any number of private
packages (storage and transfer have free quotas). Use `ghcr.io/<owner>/<app>` as
the image name in both files, log in with
`registry: ghcr.io`, `username: ${{ github.actor }}`,
`password: ${{ secrets.GITHUB_TOKEN }}`, give the job `packages: write`, and
on the VPS `docker login ghcr.io` with a token that has `read:packages`. Check
the package's visibility after the first push.
