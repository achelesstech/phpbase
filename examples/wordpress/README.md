# WordPress on php-base

A complete starting point for a WordPress site on `achelesstech/php-base:8.4`:
a deployment repository, local development, and a hardened production stack
behind Traefik (`examples/traefik`).

WordPress core is not your code: the Dockerfile downloads a pinned release at
build and verifies its checksum. What is yours (themes, plugins, mu-plugins)
lives in `wp-content/` in this repository and is baked into the image. One
repository per site.

| File | What it is |
|---|---|
| `Dockerfile` | `site` (core + wp-cli downloaded and verified, your `wp-content/` and `wp-config.php` over it), `production`, `dev` |
| `docker/wp-config.php` | every setting from the environment; `DISALLOW_FILE_MODS` and `DISABLE_WP_CRON` on |
| `wp-content/` | your themes, plugins and mu-plugins (empty to start) |
| `compose.yml` | local development: target `dev`, your `wp-content` directories bind-mounted, http://localhost:8080 |
| `compose.prod.yml` | production: `app`, `scheduler`, `migrate` (profile `ops`), `db` (MariaDB 11.4) |
| `.env.example` | every setting, documented |
| `.github/workflows/build-app.yml` | build, boot with `compose.prod.yml`, install, assert a real 200, Trivy, push |
| `renovate.json` | keeps both base digests current, plus MariaDB |
| `.dockerignore`, `.hadolint.yaml` | build context and lint policy |

Nginx comes from the base: the Dockerfile links the `wordpress.conf` preset
(`/etc/nginx/presets/wordpress.conf`), which already refuses PHP in
`wp-content/uploads`, hides `wp-config.php` and denies `xmlrpc.php`. Extra
`location` blocks go into `/etc/nginx/server.d/*.conf` at build time; there is
no vhost to maintain. Nginx ignores `.htaccess`: a plugin that writes rules
there needs them as a `server.d` file.

## 1. Copy it into the site repository

```bash
SITE=~/code/my-site
mkdir -p "$SITE" && cp -r examples/wordpress/. "$SITE/"
cd "$SITE"
cp .env.example .env                 # then fill it in (below)
```

Then commit your theme to `wp-content/themes/<name>/` and your plugins to
`wp-content/plugins/<name>/`. They are copied over the themes and plugins core
ships.

**Upgrading WordPress** is a commit: set `WORDPRESS_VERSION` and its
`WORDPRESS_SHA1` in the Dockerfile together,

```bash
curl -fsS https://downloads.wordpress.org/release/wordpress-X.Y.Z.tar.gz.sha1
```

deploy, then run `migrate` (below). wp-cli is pinned the same way
(`WP_CLI_VERSION`, `WP_CLI_SHA512`).

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
site image whenever the base is rebuilt, and last week's build could not be
reproduced. A tag-only reference still builds when you need one:
`docker build --build-arg PHP_BASE_IMAGE=docker.io/achelesstech/php-base:8.4 …`.

**Renovate** (`renovate.json`) then keeps both digests current in one PR, every
Monday. That PR is the CVE patch path: the base is rebuilt weekly. It never
moves the PHP line (8.4 → 8.5); change both tags by hand for that. It also
keeps the MariaDB digest current, within 11.4.

## 3. Local development

```bash
docker compose up -d --build
docker compose exec app wp core install --url=http://localhost:8080 --title=Dev \
    --admin_user=admin --admin_password=admin --admin_email=admin@example.com --skip-email
```

`compose.yml` bind-mounts `wp-content/mu-plugins`; add one line per theme or
plugin you work on (examples in the file). Mounting the whole `wp-content/`
would hide the themes and plugins core ships. OPcache re-checks file times
(`PHP_OPCACHE_VALIDATE_TIMESTAMPS=1`), so edits show up without a rebuild.
Xdebug is loaded but off until you ask for it:
`XDEBUG_MODE=debug docker compose up -d`.

## 4. Production

On the VPS, next to a running `examples/traefik` (which creates the `proxy`
network):

```bash
cp .env.example .env                 # APP_DOMAIN, TRAEFIK_ROUTER, TRAEFIK_CERT_RESOLVER, WORDPRESS_SECRET, WORDPRESS_DB_PASSWORD
docker compose -f compose.prod.yml pull                     # or: build
docker compose -f compose.prod.yml up -d
# First deploy only:
docker compose -f compose.prod.yml exec app wp core install --url="https://www.example.com" \
    --title="My Site" --admin_user=… --admin_password=… --admin_email=… --skip-email
```

| Service | Role | `mem_limit` |
|---|---|---|
| `app` | web: nginx + PHP-FPM; healthy when `/fpm-ping` and `/wp-login.php` answer | 1g |
| `scheduler` | `php-base-every 60 wp cron event run --due-now`; healthy while runs keep succeeding | 512m |
| `migrate` | `wp core update-db`, profile `ops`, after a WordPress upgrade | 512m |
| `db` | MariaDB 11.4 | — |

**WP-Cron** runs from `scheduler`, every minute, not on page views
(`DISABLE_WP_CRON`): on a quiet site page-view cron runs late, and on a busy
one it slows requests down. Any other `wp` command runs in the app container:
`docker compose -f compose.prod.yml exec app wp plugin list`.

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
  (64M) fit in 256m. Raising `PHP_UPLOAD_MAX_FILESIZE` and `PHP_POST_MAX_SIZE`
  for large media? Raise the tmpfs, then `mem_limit` by as much again, or the
  pool shrinks. Cloudflare's free plan caps a request at 100 MB anyway.
- **More workers:** raise `mem_limit`; each 64 MiB adds one. `FPM_MAX_CHILDREN`
  also takes a fixed number. The app container logs its choice at start:
  `fpm: max_children=7 (limit 1024M, worker 64M, reserve 576M)`.

### Read-only root

Every WordPress container runs with `read_only: true`, `cap_drop: [ALL]`,
`no-new-privileges`, a `pids_limit` and a sized `/tmp` tmpfs. The code is
root-owned; PHP cannot change it. What that means for the site:

- **`wp-content/uploads` is the one writable path** (the `wp-uploads` volume):
  the media library. Images are resized with Imagick (JPEG, PNG, GIF, WebP,
  AVIF, HEIC).
- **No installs or updates from the admin** (`DISALLOW_FILE_MODS`, which also
  removes the theme and plugin editor). Plugins and themes are commits; core
  is `WORDPRESS_VERSION`. Plugins that write their own files outside uploads
  (some caching and security plugins) need that path made a volume, or a
  different plugin.
- **`wp-config.php` is baked, not generated at start**: it reads the
  environment, so `.env` is the whole configuration. Logs go to the container output
  (`docker compose logs app`).

## 5. Registry: keep the site image private

The site image contains your code. Its repository must be **private**.

`build-app.yml` pushes to Docker Hub as `docker.io/achelesstech/wordpress-app`.
That name is one variable at the top of `build-app.yml` (`APP_IMAGE`) and of
`compose.prod.yml` (`x-image`); rename it in both, together. Before the first
push:

1. Create the repository on Docker Hub as **private**. Docker Hub's free plan
   allows only one private repository; a second site needs a paid plan or GHCR.
2. Set `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` (a Read & Write access token,
   not the password) as secrets on the site's GitHub repository.

**GHCR (GitHub Container Registry)** is the alternative: any number of private
packages (storage and transfer have free quotas). Use `ghcr.io/<owner>/<site>`
as the image name in both files, log in with
`registry: ghcr.io`, `username: ${{ github.actor }}`,
`password: ${{ secrets.GITHUB_TOKEN }}`, give the job `packages: write`, and
on the VPS `docker login ghcr.io` with a token that has `read:packages`. Check
the package's visibility after the first push.
