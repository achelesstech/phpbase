# Moodle on php-base

A complete starting point for a Moodle 5.3 LTS site on
`achelesstech/php-base:8.4`: a multi-stage image, local development, and a
hardened production stack behind Traefik (`examples/traefik`).

This is a **deployment repository**, one per site. Moodle itself is not in
it: the image downloads the release tarball of the branch at build. The
repository holds this directory, `config.php`, and any plugins the site adds.

| File | What it is |
|---|---|
| `Dockerfile` | `source` (release tarball + `composer install`, in the `-dev` base), `production`, `dev` |
| `docker/config.php` | Moodle's `config.php`, baked root-owned; every per-site value comes from the environment |
| `compose.yml` | local development: target `dev`, `config.php` bind-mounted, http://localhost:8080 |
| `compose.prod.yml` | production: `app`, `scheduler`, `install` and `migrate` (profile `ops`), `db` (PostgreSQL 18) |
| `.env.example` | every setting, documented |
| `.github/workflows/build-app.yml` | build, boot with `compose.prod.yml`, install, assert a real 200, Trivy, push |
| `renovate.json` | keeps both base digests current, plus PostgreSQL |
| `.dockerignore`, `.hadolint.yaml` | build context and lint policy |

Nginx comes from the base: the Dockerfile links the `moodle.conf` preset
(`/etc/nginx/presets/moodle.conf`: the `public/` docroot of Moodle 5.1+, the
Routing Engine, slash arguments, X-Accel-Redirect from moodledata). Extra
`location` blocks go into `/etc/nginx/server.d/*.conf` at build time; there is
no vhost to maintain.

## 1. Copy it into the deployment repository

```bash
SITE=~/code/lms-example-com
mkdir -p "$SITE" && cp -r examples/moodle/. "$SITE/"
cd "$SITE" && git init
cp .env.example .env                 # then fill it in (below)
```

### Moodle version

The Dockerfile builds `MOODLE_503_STABLE` (5.3 LTS), the version the base
image's tests install. It uses the `public/` layout the preset serves, and
keeps the CLI scripts in `admin/cli/`, outside the docroot. The build takes
the newest weekly build of the branch; `build-app.yml` rebuilds every Tuesday
to pick up Moodle's fixes. After a new image, run `migrate` (below).

### Plugins

Plugins live in the repository and are copied in at build, never installed
from the web UI: the code is root-owned and `$CFG->disableupdateautodeploy` is
set. Put each one under `plugins/` and add a `COPY` line to the `source` stage,
as the comment there shows, then deploy and run `migrate`.

## 2. The two base digests

The Dockerfile starts with two arguments, each pinned by digest to a published
build of the 8.4 line, so the app image builds as copied:

```dockerfile
ARG PHP_BASE_IMAGE=docker.io/achelesstech/php-base:8.4@sha256:…
ARG PHP_BASE_DEV_IMAGE=docker.io/achelesstech/php-base:8.4-dev@sha256:…
```

`:8.4` alone would change the app image whenever the base is rebuilt, and
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
docker compose exec app php admin/cli/install_database.php --agree-license \
    --adminuser=admin --adminpass='Admin-dev-1!' --adminemail=admin@example.com \
    --fullname='Moodle dev' --shortname=dev
```

http://localhost:8080. `config.php` is bind-mounted and OPcache re-checks file
times (`PHP_OPCACHE_VALIDATE_TIMESTAMPS=1`), so edits show up without a
rebuild. A plugin you are writing can be bind-mounted into its place under
`public/` the same way (see `compose.yml`). Xdebug is loaded but off until
you ask for it: `XDEBUG_MODE=debug docker compose up -d`.

## 4. Production

On the VPS, next to a running `examples/traefik` (which creates the `proxy`
network):

```bash
cp .env.example .env                 # APP_DOMAIN, TRAEFIK_ROUTER, TRAEFIK_CERT_RESOLVER, DB_PASSWORD, MOODLE_ADMIN_*
docker compose -f compose.prod.yml pull                     # or: build
docker compose -f compose.prod.yml up -d db app
docker compose -f compose.prod.yml run --rm install         # first deploy only (a few minutes)
docker compose -f compose.prod.yml up -d
```

Every deploy after that:

```bash
docker compose -f compose.prod.yml pull
docker compose -f compose.prod.yml run --rm migrate         # maintenance on, upgrade.php, maintenance off
docker compose -f compose.prod.yml up -d
```

`.env` is read only to fill in `compose.prod.yml`; each container gets just
the variables listed there. The `MOODLE_ADMIN_*` values reach the `install`
one-shot alone, so the admin password never sits in the environment of `app`
or `scheduler`.

The install and the upgrade run from one-shot services, never from every
container's entrypoint, where they would run concurrently. `migrate` leaves
maintenance mode on if the upgrade fails.

| Service | Role | `mem_limit` | `/tmp` |
|---|---|---|---|
| `app` | web: nginx + PHP-FPM; healthy when PHP-FPM answers | 2g | volume `app-tmp` |
| `scheduler` | `php-base-every 60 php admin/cli/cron.php --keep-alive=0`; healthy while runs keep succeeding | 512m | tmpfs 256m |
| `install` | `admin/cli/install_database.php`, profile `ops`, run once by hand | 1g | tmpfs 256m |
| `migrate` | `admin/cli/upgrade.php` inside maintenance mode, profile `ops`, run by hand | 1g | tmpfs 256m |
| `db` | PostgreSQL 18 | — | — |

`--keep-alive=0` makes each cron run do one pass and exit. Moodle's default
keeps `cron.php` polling for three minutes, longer than the one-minute
interval, and the scheduler would only ever succeed every few minutes.

The scheduler's 512m `mem_limit` covers ordinary cron runs, but asynchronous
backups and restores of large courses run in the scheduler too and can need
more. If they fail with an out-of-memory kill (`docker compose ps` shows the
scheduler restarted; `dmesg` names the OOM), raise `mem_limit` on `scheduler`
in `compose.prod.yml` (1g or 2g), and `PHP_MEMORY_LIMIT` with it if PHP itself
reports the limit.

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

### Behind Traefik: wwwroot and the client address

`config.php` sets `$CFG->wwwroot` to `https://${APP_DOMAIN}` and turns on
`$CFG->sslproxy` for an https wwwroot. Moodle redirects any other host name
to the wwwroot, so the site answers only on `APP_DOMAIN`.

`$CFG->getremoteaddrconf = 3` makes Moodle read the client address from
`REMOTE_ADDR` only, never from `X-Forwarded-For` or `Client-IP`. nginx already
sets `REMOTE_ADDR` from Traefik's `X-Forwarded-For`, trusting only private
ranges and Cloudflare's edge, so a client cannot forge the address Moodle
logs, rate-limits and locks out.

### Upload limits

The largest file a user can upload, course backups included, is set in
`compose.prod.yml` (override in `.env`):

| Setting | Default here | Base default |
|---|---|---|
| `PHP_UPLOAD_MAX_FILESIZE` | `512M` | `64M` |
| `PHP_POST_MAX_SIZE` | `512M` | `64M` |
| `PHP_MEMORY_LIMIT` | `512M` | `256M` |

- nginx's `client_max_body_size` follows `post_max_size` by itself.
- Moodle's own limits sit below these: *Site administration > Security > Site
  security settings > Maximum uploaded file size*, then per course and per
  activity. They can never exceed `upload_max_filesize`.
- The image raises all three request timeouts to 600 s for long admin pages,
  backups and restores: `PHP_MAX_EXECUTION_TIME=600` (base default 120),
  `FPM_REQUEST_TERMINATE_TIMEOUT=600s` and `NGINX_FASTCGI_READ_TIMEOUT=600s`
  (base defaults 300s).
- **Traefik** reads the whole request body within its `readTimeout`. A large
  upload on a slow line needs more than the 60s default; `examples/traefik`
  raises it on `websecure`. Keep it at least 600s.

### `/tmp` on a volume, memory and `FPM_MAX_CHILDREN=auto`

PHP writes an upload to `/tmp` while it receives it. The other examples keep
`/tmp` on a tmpfs sized at 2 × `post_max_size` + 32 MB. For 512M uploads that
is over 1 GB of RAM charged to `mem_limit`. So `app` mounts the named volume
`app-tmp` on `/tmp` instead: uploads in flight are on disk. The CLI containers
take no uploads and keep a 256m tmpfs.

What the volume changes:

- It is not mounted `noexec,nosuid,nodev` like the tmpfs. The root is still
  read-only and every capability dropped. `app-tmp` is the one writable path
  besides moodledata.
- It survives restarts. The base wipes and re-renders its runtime directory
  `/tmp/php-base` at every start, and PHP deletes upload files at the end of
  each request. Give each container its own `/tmp` volume: never share
  `app-tmp` with another service, because each start wipes `/tmp/php-base`.
- Moodle's own temporary files and caches are in moodledata
  (`$CFG->tempdir`, `cachedir`, `localcachedir`), not in `/tmp`.

The base sizes the PHP-FPM pool from the container's memory limit
(`FPM_MAX_CHILDREN=auto`, the default). A `/tmp` that is not a tmpfs costs no
RAM, so nothing is reserved for it:

```
workers = (mem_limit − (OPcache + 64 MiB + /tmp tmpfs size)) / 64 MiB      clamped to 2–64
        = (2048 − (256 + 64 + 0)) / 64 = 27                                for app
```

- **More workers:** raise `mem_limit`; each 64 MiB adds one. `FPM_MAX_CHILDREN`
  also takes a fixed number. The app container logs its choice at start:
  `fpm: max_children=27 (limit 2048M, worker 64M, reserve 320M)`.
- `PHP_MEMORY_LIMIT` (512M) is a per-request ceiling, not the average:
  a Moodle request averages well under 64 MiB, and only backups and restores
  approach the ceiling.

### Read-only root

Every Moodle container runs with `read_only: true`, `cap_drop: [ALL]`,
`no-new-privileges` and a `pids_limit`. The code and `config.php` are
root-owned; PHP cannot change them. What that means for the site:

- **moodledata is the writable path** (the `moodledata` volume at
  `/var/moodledata`): files, sessions, caches, temp. It is shared by `app`,
  `scheduler`, `install` and `migrate`, outside the docroot.
- **Plugins and updates arrive with a new image** (see
  [Plugins](#plugins)); the web UI cannot install them.
- **Executable paths** (`pathtophp`, `pathtogs`) are fixed in `config.php` and
  locked from the admin UI (`$CFG->preventexecpath`).
- **Sessions** are files in moodledata. Running more than one `app` replica
  needs a shared session store (Redis): add it to `config.php` first.

## 5. Registry: keep the app image private

The app image contains your configuration and plugins. Its repository must be
**private**.

`build-app.yml` pushes to Docker Hub as `docker.io/achelesstech/moodle-app`.
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
