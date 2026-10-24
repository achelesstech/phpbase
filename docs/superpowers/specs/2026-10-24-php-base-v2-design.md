# php-base v2 — design

- **Date:** 2026-10-24
- **Branch:** `feat/php-base-v2`. Baseline commit `38b9bc0` holds the Docker Hub migration that was uncommitted on `main`.
- **Status:** approved in conversation; this document writes that agreement down.

---

## 1. Why

`achelesstech/php-base` is the base image for the owner's PHP sites:
- FarmBook and HQ, both Laravel;
- future Laravel, Drupal, Moodle and WordPress sites.

Every site runs behind one Traefik on a VPS. Cloudflare sits in front for some of the domains but not all of them.

The current image has three problems.

**It froze.** It pins `ALPINE_VERSION=3.21`. Docker's official PHP images stopped building that variant, so the 8.4 line stayed on PHP 8.4.15 and nobody noticed. That leaves it exposed to:
- **PHP2Shell** (CVE-2026-109618 and CVE-2026-109619, PHP-FPM, CVSS 9.2), fixed on 2026-10-21 in 8.5.12, 8.4.27, 8.3.36 and 8.2.35;
- 46 fixable HIGH/CRITICAL OS vulnerabilities found by Trivy.

**It is bigger and more exposed than it needs to be.**
- Its process manager is supervisord. That brings in Python: 46 MB of the image and 24 MB of RAM per container.
- PHP source and headers are shipped in production.
- Composer is in production.
- PHP-FPM listens on TCP.
- The status pages sit on the public port.

**It doesn't fit Traefik well.**
- nginx closes keep-alive connections at 65 s, but Traefik reuses them for up to 90 s.
- Both nginx and Traefik compress responses.
- Both log every request.
- New containers take about 30 s to become healthy, and Traefik routes only to healthy containers.

A tested prototype of most of v2 exists at `/tmp/php-base-next`. It is a copy of this repo:
- **baseline commit:** `3078aa2`;
- **changes:** unstaged, so `git -C /tmp/php-base-next diff` and `git -C /tmp/php-base-next status` show everything.

On 2026-10-24 it passed, on amd64, for 8.2, 8.3, 8.4 and 8.5:
- 56/56 runtime checks and 8/8 dev checks;
- real installs of Laravel, Drupal, WordPress and Moodle on the versions each one supports;
- Trivy with 0 fixable HIGH/CRITICAL findings.

v2 is that prototype plus the changes agreed afterwards (§6). **`/tmp` does not survive a reboot**, so the first implementation task copies the prototype into this branch.

The repo also holds starting-point examples that get copied into new projects: app templates, the Traefik host setup and Portainer. They have to match v2 and be organised.

---

## 2. Goals

| # | Goal | How we know |
|---|---|---|
| G1 | **Latest.** Every build uses the newest PHP patch of 8.2/8.3/8.4/8.5 and the newest Alpine the official PHP image ships, with every Alpine package upgraded | Resolver output; guard rails (§7.11) fail or warn when it isn't true |
| G2 | **Fast security uptake.** A new upstream PHP image, a new Alpine base image, or a pending Alpine package update is rebuilt within ~6 hours | `watch-upstream.yml` runs every 6 h (§6b C3) |
| G3 | **Fits the four frameworks.** Laravel 12/13, Drupal 11, Moodle 5.1–5.3, WordPress 7.x | Framework smoke tests in CI, per `versions.json` |
| G4 | **Secure.** Details below the table | Runtime test suite (§7.10), run under the hardened flags |
| G5 | **Small.** 8.4 runtime **≤ 180 MB** uncompressed on amd64 (prototype: 239 MB), with no extension dropped | Per-line size ceilings in tests and CI (§6b C5) |
| G6 | **Performant behind Traefik.** No keep-alive race, no double compression, no duplicate access log, sane nginx worker count, FPM sized from the memory limit, healthy within a few seconds | Runtime tests |
| G7 | **Reproducible.** The published digest is the tested digest; images are signed and carry SBOM and provenance | Workflow structure (§7.11) |
| G8 | **Examples.** One copy-to-start example per framework, plus Traefik and Portainer, consistent with v2 | Lint workflow |
| G9 | **Tidy repo.** Docs in `docs/`, examples in `examples/`, no stale files | Layout (§7.1); link check |

What G4 (secure) requires:
- every process runs as non-root;
- no Python;
- no compilers, PHP sources, PEAR/PECL or Composer in the runtime image;
- PHP-FPM is reachable only through nginx;
- status pages are internal only;
- ImageMagick formats are restricted to an allowlist;
- the image runs with a read-only root filesystem, no capabilities and `no-new-privileges`.

## 3. Non-goals

- Compiling PHP ourselves, a Debian/glibc variant, FrankenPHP/Octane/Swoole, Kubernetes manifests.
- PHP below 8.2. An example for Moodle ≤ 5.0: the `moodle-legacy.conf` preset stays, the example doesn't.
- An FPM-only mode for an external nginx. v2 is one container serving web traffic. `FPM_POOL_EXTRA` remains the advanced escape hatch.
- Deploying the examples from this repo. CI only lints them.
- Migrating the FarmBook and HQ repos. That is a later task; `docs/migrating-from-v1.md` guides it.
- Pushing, publishing or changing GitHub/Docker Hub settings from this machine. CI publishes after the owner pushes.
- Testing arm64 locally. CI builds and tests arm64 on native runners.

## 4. Anti-goals: failure even if it "works"

- **A silent freeze.** Any published tag or default path that can stop receiving PHP or Alpine updates without a visible warning. This is why the `X.Y-alpineA.B` tags are dropped.
- **Publishing a digest other than the one that was tested.**
- **Silent behaviour loss.** For example, missing locale data, or functions disabled by default that some WordPress plugin needs.
- **Writable code at runtime.** Config or scripts that can be modified at runtime and survive a restart. Root processes.
- **Leaked secrets.** Secrets in images, image labels or logs.
- **An unnoticed size regression.**

## 5. Constraints

- **Upstream images:**
  - `php:<line>-fpm-alpine` (`php:8.6-rc-fpm-alpine` for the pre-release line), resolved to a digest on every run.
  - The runtime base is `alpine:<minor>`, where `<minor>` is the Alpine minor read from inside that PHP image, also resolved to a digest.
  - PHP's binaries link against that Alpine branch's libraries (ICU changes its soname between branches), so **the two must be the same Alpine minor**.
- **Docker Hub:**
  - The image is public at `docker.io/achelesstech/php-base`.
  - Pulls are rate-limited, so CI logs in on every job.
  - This machine is logged in as `achelesstech`.
- **GitHub Actions:**
  - Native arm64 runners (`ubuntu-24.04-arm`).
  - Scheduled runs are delayed at the top of the hour, so cron minutes avoid `:00`.
  - Schedules in a public repo are disabled after 60 days without activity; Renovate's automerges keep the repo active.
- **This machine:**
  - 8 CPUs, 7 GB RAM (about 2 GB free), 31 GB free disk.
  - Docker 29.9, buildx 0.38.
  - **Build and test sequentially.** Run at most one framework test at a time.
- **Production host:**
  - Traefik v3.6 with a shared external `proxy` network.
  - Two certificate resolvers: `cloudflare` (DNS-01) and `letsencrypt` (HTTP-01).
  - Docker ≥ 25, which `HEALTHCHECK --start-interval` needs.
- **Calendar:**
  - PHP 8.2 goes end-of-life on 2026-12-31. The resolver skips it automatically after that date.
  - PHP 8.6 GA is 2026-11-19. It's a canary that is allowed to fail; no PECL extension compiles on 8.6 yet.
  - Drupal 12, due December 2026, needs PHP 8.5.
- **Effort levels** (set by the owner):
  - implementation subagents run at **xhigh**;
  - spec and plan work and their reviews run at **max**;
  - the local builds of all eight images run on **Opus 5.5 at medium**.

---

## 6. Decisions already made

These were agreed in conversation on 2026-10-24. They aren't open.

**Base image**
1. Resolve `php:<line>-fpm-alpine` → digest on every run, then `apk upgrade` on a weekly cache-bust. *(prototype)*
2. Guard rails:
   - **fail** a line when the upstream PHP is behind php.net's latest for that branch and that release is more than 3 days old;
   - **warn** when a newer Alpine has been released for more than 14 days and the image isn't on it.
3. An upstream watcher runs **every 6 hours** and rebuilds the lines whose upstream digest changed.
4. PECL extension versions stay pinned in the Dockerfile. Renovate opens a PR when a new version appears and **automerges minor/patch updates when CI is green**.
5. **s6 replaces supervisord**. Python leaves the image.
6. The runtime image is assembled **on a clean `alpine:<minor>`**, with PHP copied in. PHP sources, headers, phpize, PEAR/PECL and the `docker-php-*` helpers ship only in `-dev`.
7. **Composer** (and `unzip`, `git`, `patch`, `openssh-client`) ship only in `-dev`. Apps run `composer install` in a `-dev` build stage.
8. **Full ICU data stays** (31.6 MB). HEIC support stays (2.8 MB).
9. PHP-FPM listens on a **Unix socket**. There is no TCP listener.
10. The status endpoints (`/fpm-ping`, `/fpm-status`, `/nginx-status`) move to an **internal listener on `127.0.0.1:8081`**. The prototype's `allow 127.0.0.1` on the public port can be bypassed: any container on the same Docker network can send `X-Forwarded-For: 127.0.0.1`.
11. An **ImageMagick allowlist policy** with resource limits.
12. **Hardened run flags**, tested in CI:
    - `read_only`;
    - `tmpfs /tmp:noexec,nosuid,nodev`;
    - `cap_drop: [ALL]`;
    - `no-new-privileges`;
    - `pids_limit`.
13. Optional **`PHP_DISABLE_FUNCTIONS`**, applied to the FPM pool only, off by default.

**Traefik-related**

14. nginx **does not compress dynamic responses by default** (Traefik already does) and serves pre-compressed `.gz` assets (`gzip_static on`).
15. nginx `keepalive_timeout 120s` (longer than Traefik's 90 s idle reuse) and `keepalive_requests 10000`.
16. `HEALTHCHECK --start-interval=2s`.
17. **nginx access log off by default**, because Traefik already logs every request.
18. `SERVER_PORT` is passed from `X-Forwarded-Port`.
19. The Moodle example sets `$CFG->getremoteaddrconf = 3`, so Moodle uses only `REMOTE_ADDR`.
20. Upload and timeout limits line up with Traefik's 600 s read timeout. The docs explain that uploads use the `/tmp` tmpfs, which is RAM.

**Performance**

21. `open_file_cache` on, `worker_processes` 2 by default, PHP-FPM worker count sized from the memory limit (`FPM_MAX_CHILDREN=auto`).

**Tags**

22. Published tags:
    - `X.Y`, `X.Y.Z`, `X.Y.Z-YYYYMMDD`, and `latest` (newest stable line, currently 8.5);
    - a `-dev` twin of each tag, with `latest-dev`;
    - for 8.6, only `8.6-rc` and `8.6-rc-dev`.

    **No `X.Y-alpineA.B` tags.** Local builds are named `local/php-base:X.Y[-dev]`.

**Certificates**

23. Domains on Cloudflare use the `cloudflare` resolver (DNS-01). Every other domain uses `letsencrypt` (HTTP-01), wherever its DNS is hosted (Namecheap, GoDaddy, a local company…).
    - Each app example's `.env` has `TRAEFIK_CERT_RESOLVER=cloudflare|letsencrypt`.
    - Let's Encrypt stopped sending expiry emails in 2025, so the Traefik scripts check expiry themselves.

**Repo, examples and git**

24. The layout in §7.1. These are removed:
    - `laravel11`: Laravel 11 security support ended in March 2026.
    - `moodle50`: Moodle 5.0 is out of support.
    - `moodle52`: folded into the `moodle` example (5.3 LTS, with a one-line switch to 5.2).
25. Examples are starting points copied into a project. CI lints them; it never deploys them.
26. All work happens on `feat/php-base-v2`, with one commit per plan task. **Nothing is pushed** without asking.

## 6b. Calls made while writing this down

A builder check of this document raised these points. **They are the author's calls, not the owner's**, and they are listed here so the owner can check them.

- **C1 — Memory. `/tmp` is a tmpfs, so it is RAM charged to the container's memory limit.**
  - `FPM_MAX_CHILDREN=auto` reserves the `/tmp` tmpfs size on top of OPcache and the 64 MiB base (§7.6).
  - The ImageMagick policy caps what a single operation can use in total (memory + map + disk), so a huge image fails with a clean error instead of an OOM kill (§7.8).
  - The examples' `mem_limit` values are sized to match (§7.12).
- **C2 — Hooks keep the prototype's behaviour.** A hook that isn't root-owned, or that is writable by group or others, logs a **warning**; `PHP_BASE_STRICT=1` turns the warning into a refusal.
  - The check itself is fixed. The prototype tests `-w`, which misses a hook owned by `www-data` with mode 0555, because the owner can chmod it back. The check now looks at ownership and mode.
  - This is therefore not a breaking change. Dev bind mounts, which are owned by uid 1000, only warn.
- **C3 — The watcher rebuilds a line when any of three things change** (G2):
  - the upstream PHP image digest;
  - the `alpine:<minor>` digest;
  - the published image has pending `apk` upgrades (the watcher runs `apk upgrade --simulate` in it).

  Because builds can now happen more than once a day, the build tag becomes `X.Y.Z-YYYYMMDD`, or `X.Y.Z-YYYYMMDD.N` (N = 2, 3, …) when that tag already exists, so a published build tag never changes (§7.2).
- **C4 — The tests cover every framework version this document or the examples promise.**
  - In `versions.json`, a framework's value can be a list.
  - The resolver and the test runner iterate over the list.
  - The matrix is in §7.10.
- **C5 — Size ceilings are per line**, kept in `versions.json` as `max_size_mb`:

  | Line | Ceiling |
  |---|---|
  | 8.2 | 175 MB |
  | 8.3 | 178 MB |
  | 8.4 | 180 MB |
  | 8.5 | 198 MB |

  The basis: the prototype's sizes (230/235/239/256 MB) minus the ~67 MB that §6 items 5–7 remove, plus a small margin. A build over its ceiling fails.

---

## 7. Design

### 7.1 Repository layout

```
.
├── Dockerfile                    multi-stage; §7.3
├── rootfs/                       files for the runtime image
├── rootfs-dev/                   additions for the -dev image
├── versions.json                 build matrix: lines, EOL, latest, prerelease, frameworks
├── scripts/                      resolve-matrix.sh, update-cloudflare-ips.sh, check-links.sh, …
├── test/                         run.sh, run-dev.sh, frameworks/, fixtures
├── Makefile                      build, build-all, test, test-frameworks, lint, scan, …
├── renovate.json
├── .github/workflows/            build-base.yml, watch-upstream.yml, lint.yml
├── .hadolint.yaml  .dockerignore  .gitignore
├── README.md                     short: what it is, tags, quick start, links into docs/
├── CHANGELOG.md
├── docs/
│   ├── README.md                 index
│   ├── image.md                  contents, runtime contract, roles, env reference, presets, tuning
│   ├── security.md               threat model, hardening, run flags, what the tests prove
│   ├── publishing.md             pipeline, tags, Docker Hub + GitHub setup, Renovate, watcher, cosign verify
│   ├── reverse-proxy.md          Traefik + Cloudflare: IP chain, certs, keep-alive, compression, timeouts, uploads
│   ├── migrating-from-v1.md      breaking changes and steps (FarmBook/HQ notes)
│   ├── docker-hub.md             text for the Docker Hub page
│   ├── traefik/                  labels.md, static-config.md, vps-setup.md, audit-previous-config.md
│   ├── portainer/                audit-docker-run.md
│   └── superpowers/              specs/, plans/
└── examples/
    ├── README.md
    ├── laravel/                  Laravel 13 (Laravel 12 by changing one constraint)
    ├── drupal/                   Drupal 11
    ├── wordpress/
    ├── moodle/                   Moodle 5.3 LTS (5.2 by changing one line)
    ├── traefik/                  the host's edge proxy, improved (§7.13)
    └── portainer/
```

Moves use `git mv`, so history is kept.

| From | To |
|---|---|
| `apps/laravel13/` | `examples/laravel/` |
| `apps/drupal11/` | `examples/drupal/` |
| `apps/wordpress/` | `examples/wordpress/` |
| `apps/moodle52/` | `examples/moodle/` (then moved up to 5.3) |
| `apps/README.md` | `examples/README.md` |
| `apps/laravel11/`, `apps/moodle50/` | deleted |
| `traefik/` (compose, config/, scripts/, Makefile, env, keep-files, README) | `examples/traefik/` |
| `traefik/LABELS.md`, `STATIC-CONFIG.md`, `VPS-SETUP.md` | `docs/traefik/labels.md`, `static-config.md`, `vps-setup.md` |
| `traefik/AUDIT.md` | `docs/traefik/audit-previous-config.md` |
| `portainer/` (all but AUDIT) | `examples/portainer/` |
| `portainer/AUDIT.md` | `docs/portainer/audit-docker-run.md` |

The prototype's documents are merged into `docs/`. None of them is committed as-is:

| Prototype file | Where its content goes |
|---|---|
| `PROPOSAL.md` | rationale goes to the relevant `docs/` pages; §7 (FarmBook/HQ) goes to `docs/migrating-from-v1.md` |
| `README.hub.md` | `docs/docker-hub.md` |
| `VERIFICATION.md` | not committed (a point-in-time report); CI job summaries replace it |

Every relative link must resolve after the moves. `scripts/check-links.sh` checks this, and the lint workflow runs it.

### 7.2 Variants, tags, labels

**Variants:**
- **runtime** (`X.Y`): production.
- **dev** (`X.Y-dev`): runtime plus development and build tools (§7.3). Used for local development and as the `composer install` build stage.

**Tags** are listed in §6 item 22. Tag mechanics:
- The date is the build's UTC date. If `X.Y.Z-YYYYMMDD` already exists on Docker Hub, the resolver uses the next free `X.Y.Z-YYYYMMDD.N` (§6b C3).
- `latest` goes to the line marked `"latest": true` in `versions.json`.
- 8.6 builds are allowed to fail, and get tags only when they pass.

**Labels:**
- The OCI standard set. `org.opencontainers.image.base.name` and `base.digest` describe the **Alpine** image the runtime stage is built on.
- These custom labels:

  | Label | Content |
  |---|---|
  | `io.github.achelesstech.php-base.upstream-image` | e.g. `php:8.4-fpm-alpine` |
  | `io.github.achelesstech.php-base.upstream-digest` | digest of that image; the watcher compares against it |
  | `io.github.achelesstech.php-base.php-version` | e.g. `8.4.27` |
  | `io.github.achelesstech.php-base.alpine-version` | e.g. `3.24.3` |
  | `io.github.achelesstech.php-base.variant` | `runtime` or `dev` |

The same facts go into `/etc/php-base/release`, which `php-base-info` reads.

### 7.3 Build (Dockerfile)

**Build arguments** (CI resolves them and passes them in; local builds get them from `scripts/resolve-matrix.sh` through the Makefile):

| Argument | Content |
|---|---|
| `PHP_VERSION` | the line, e.g. `8.4` |
| `PHP_IMAGE` | `php:8.4-fpm-alpine@sha256:…` |
| `ALPINE_IMAGE` | `alpine:3.24@sha256:…` |
| `COMPOSER_IMAGE` | `composer/composer:2-bin@sha256:…` |
| `PKG_CACHE_BUST` | the build date; refreshes the `apk upgrade` layer |
| PECL versions | each marked with a Renovate comment |
| metadata args | build date, git ref, etc., declared as late as possible, because an argument invalidates the cache of every later step |

**Stages:**

1. **`php-upstream`**: `FROM ${PHP_IMAGE}`. The source of PHP and the build toolchain.
2. **`ext-builder`**: builds every extension, exactly as in the prototype:
   - PECL tarballs plus `docker-php-ext-install`, because 8.6 images have no `pecl`;
   - igbinary 3.2.17RC1;
   - redis with igbinary/zstd/lz4;
   - memcached with igbinary/json/session/sasl;
   - gd with freetype/jpeg/webp/avif;
   - imagick, apcu, uploadprogress, and the bundled extensions.

   It then stages the runtime file set into `/out` (allowlist below).
3. **`ext-builder-dev`**: xdebug and pcov, built the same way. A missing build is fatal unless `ALLOW_MISSING_DEV_EXTENSIONS=1` (8.6 canary only).
4. **`runtime`**: `FROM ${ALPINE_IMAGE}`. In order:
   1. upgrade and install packages;
   2. copy `/out` from `ext-builder`;
   3. install the libraries PHP and its extensions need, computed with `scanelf` (this includes GNU libiconv, which upstream PHP links, so `//TRANSLIT` keeps working);
   4. recreate `www-data` as 1000:1000 with home `/home/www-data` (0750);
   5. copy `rootfs/`;
   6. normalise ownership and modes (config root-owned, read-only);
   7. run the build-time self-checks (below).
5. **`dev`**: `FROM runtime`. Adds:
   - from `php-upstream`: `/usr/src/php.tar.xz`, `/usr/local/include/php`, `phpize`, `php-config`, `/usr/local/lib/php/build`, the `docker-php-*` helpers, and PEAR/PECL where that line has them;
   - `ENV PHPIZE_DEPS`, with the same value as upstream;
   - composer from `${COMPOSER_IMAGE}`;
   - git, openssh-client, patch, unzip;
   - xdebug and pcov, installed but disabled (`xdebug.mode=off`, `pcov.enabled=0`);
   - `rootfs-dev/`.

**What the runtime contains under `/usr/local`:**

| Kept | Excluded |
|---|---|
| `bin/php`, `sbin/php-fpm` | `/usr/src/php.tar.xz` |
| `lib/php/extensions/**` (every built `.so`, including opcache) | `include/` |
| `etc/php/conf.d/docker-php-ext-*.ini` | `lib/php/build/` |
| `etc/php-fpm.conf` | `bin/phpize`, `bin/php-config`, `bin/docker-php-*` |
| | `bin/pear`, `bin/pecl`, `bin/peardev`, PEAR's PHP files and registry |
| | `php/man` |
| | `php-cgi` and `phpdbg`, if present |

Our own `zz-base.ini` and `php-fpm.d/www.conf` come from `rootfs/`.

**Runtime Alpine packages:** `ca-certificates curl tzdata tini s6 nginx imagemagick imagemagick-heic imagemagick-jpeg imagemagick-webp icu-data-full`, plus the libraries `scanelf` reports. Nothing else.

**Build-time self-checks.** The build fails if any of these fails:
- `php -m` prints no warning and no "unable to load";
- `php -v`;
- `php-base-validate` (nginx and FPM configs with a skeleton runtime dir);
- no file is owned by UID or GID 82 (with busybox `find`, use `-user`/`-group`, not `-uid`);
- there are no setuid/setgid files;
- `python3` doesn't exist;
- none of the excluded paths exists;
- `composer` doesn't exist in runtime and does exist in dev.

**Prototype rules kept:**
- `set -eux -o pipefail` inside each `RUN`. There is no `SHELL` instruction, because app images would inherit it.
- `! pipeline` is never used as an assertion, because `set -e` ignores it.
- `grep -q` is never used at the end of a pipefail pipe.

### 7.4 Process supervision (s6)

**Web role.** The default `CMD` becomes `["php-base-web"]`. The entrypoint detects the web role when the command is `php-base-web`; any other command is the CLI role, as in the prototype.

**Services.** The entrypoint renders an s6 scan directory in `/tmp/php-base/` for these services:

| Service | When it runs |
|---|---|
| `php-fpm` | always |
| `nginx` | always; starts once the FPM socket exists, or after at most 10 s |
| `scheduler` | if `SCHEDULER_COMMAND` is set: `php-base-every --name scheduler ${SCHEDULER_INTERVAL:-60} -- $SCHEDULER_COMMAND` |
| `worker` | if `WORKER_COMMAND` is set |

**Where things live:**
- Service definitions (run and finish scripts, stop signals, kill timeouts) are **root-owned files under `/etc/php-base/s6/`**.
- The scan directory and s6's state directories are under `/tmp/php-base/` and are recreated at every start.
- Nothing the services execute is writable at runtime.
- There is no control interface beyond what s6 keeps under `/tmp/php-base/`.

**Required behaviour.** These are acceptance criteria, and every one is covered by a runtime test:

1. **Graceful stop.** `docker stop` (SIGTERM to tini, which forwards it to s6):
   - nginx receives SIGQUIT and php-fpm receives SIGQUIT, so in-flight requests finish;
   - scheduler and worker receive SIGTERM;
   - a request already in flight when the stop starts completes with 200;
   - the container exits 0 when everything stops within its timeout. Kill timeouts are 15 s for nginx, 30 s for FPM and 120 s for scheduler/worker, so compose `stop_grace_period` must cover them; the examples set it.
2. **Fail fast.** If nginx or php-fpm exits on its own, the whole container exits **non-zero within 5 s**, and the restart policy takes over.
3. **Restart.** If the scheduler or worker exits, it restarts after at least 1 s and the container stays up. Laravel's `queue:work --max-time` exits on purpose and relies on this.
4. **Logs.** Every service writes straight to the container's stdout/stderr, with no relay process. Entrypoint logs stay on stderr.
5. **Users.** PID 1 is tini, and every process runs as `www-data`.

Removed: `supervisord.conf`, `supervisor-fatal-listener.sh`, every `%(ENV_…)s`, and the `/etc/supervisor` tree.

The exact s6 mechanics are the builder's choice, as long as the behaviours above hold. That covers how the finish scripts trigger a shutdown and how the exit code reaches PID 1.

### 7.5 nginx

Changes to the prototype's `nginx.conf` and snippets:

**Workers.** `worker_processes` comes from `NGINX_WORKER_PROCESSES`; the default is `2`, and `auto` is allowed. It's rendered into a main-context include at `/tmp/php-base/nginx/main.d/`.

**FastCGI target.** `upstream php_fpm { server unix:/tmp/php-base/php-fpm.sock; }` lives in `http{}`. Every snippet uses `fastcgi_pass php_fpm;`.

**Fixed `http{}` settings:**
- `keepalive_timeout 120s; keepalive_requests 10000;`
- `gzip_static on;`
- dynamic `gzip` is off unless `NGINX_GZIP=1`, which renders `gzip on` with the prototype's type list;
- `open_file_cache max=10000 inactive=60s; open_file_cache_valid 30s; open_file_cache_min_uses 2; open_file_cache_errors off;` (errors are not cached, so a file uploaded a moment ago is found).

**Access log.** `NGINX_ACCESS_LOG=off|main|json`; the default is **off**.

**Internal status server.** A server on `listen 127.0.0.1:8081` serves `/fpm-ping` and `/fpm-status` (through FastCGI) and `/nginx-status` (`stub_status`).
- It's included from the base config, not from presets.
- `health.conf` is deleted, and the presets no longer include it.
- On the public port, those paths are ordinary application paths. With the Laravel preset they reach `index.php` and get the app's 404.

**Forwarded port.** `map $http_x_forwarded_port $fcgi_server_port { default $server_port; "~^[0-9]+$" $http_x_forwarded_port; }`, and `fastcgi_param SERVER_PORT $fcgi_server_port;` in `fastcgi-php.conf`. The existing `HTTPS` and `HTTP_PROXY ""` params stay.

**Timeouts:**
- `fastcgi_read_timeout` is rendered at `http{}` level from `NGINX_FASTCGI_READ_TIMEOUT`, default `300s`. The presets no longer set it.
- The Moodle example sets 600 s.
- The rule, written in `docs/reverse-proxy.md`: PHP `max_execution_time` ≤ FPM `request_terminate_timeout` ≤ nginx `fastcgi_read_timeout` ≤ Traefik `readTimeout` (600 s).

**Kept from the prototype:**
- the real-IP settings: `NGINX_REAL_IP_FROM` defaults to RFC1918 + `fc00::/7`, `NGINX_TRUST_CLOUDFLARE` defaults to 1, and `NGINX_REAL_IP_HEADER`;
- `client_max_body_size` derived from PHP's effective `post_max_size`;
- request buffering left on. Traefik streams request bodies, and buffering is what stops slow uploads from tying up FPM workers.

### 7.6 PHP-FPM

**Listener.** `listen = /tmp/php-base/php-fpm.sock` with `listen.mode = 0660`. There is no TCP listener at all; a test asserts that nothing listens on 9000.

**`FPM_MAX_CHILDREN`** takes a number or `auto`; the default is `auto`. `auto` works like this:
- `L` is the cgroup memory limit: v2 `memory.max`, else v1 `memory.limit_in_bytes`. `max`, or anything ≥ 2^60, counts as unlimited.
- With no limit, the value is **12**.
- Otherwise it is `clamp(floor((L − R) / W), 2, 64)`, where:
  - `W` = `FPM_WORKER_MEMORY` (default `64M`);
  - `R` = the effective `opcache.memory_consumption` + 64 MiB + `T`;
  - `T` = the size limit of `/tmp` when `/tmp` is a tmpfs (read from the mount), else 0. Uploads and ImageMagick's cache live there, and on tmpfs they are RAM (§6b C1).

  Example: limit 1 GiB, 256 MiB OPcache, `/tmp` tmpfs of 256 MiB → R = 576 MiB → 7 workers.
- `pm.start_servers`, `pm.min_spare_servers` and `pm.max_spare_servers` scale from that value. Their `FPM_*` variables still override them.
- The entrypoint logs one line with the inputs and the result, e.g. `fpm: max_children=11 (limit 1024M, worker 64M, reserve 320M)`.

**Other settings:**
- `request_terminate_timeout` comes from `FPM_REQUEST_TERMINATE_TIMEOUT`; the default is **300s** (previously unset).
- `security.limit_extensions = .php`.
- `PHP_DISABLE_FUNCTIONS`, when set, renders `php_admin_value[disable_functions] = …` into the pool. It affects web requests only; CLI commands are untouched. Unset by default.
- Everything else as in the prototype: status and ping paths, slowlog to stderr, `clear_env = no`, and `include = /tmp/php-base/fpm/*.conf` as the last line.

### 7.7 PHP ini

As in the prototype's `zz-base.ini`. This includes `session.upload_progress.enabled=Off`, the advisory from 23 Oct 2026, and OPcache sized for Moodle 5.3's ~60k files. No changes are planned.

### 7.8 ImageMagick policy

`/etc/ImageMagick-7/policy.xml` is ours and root-owned. It is an allowlist:

| Category | Policy |
|---|---|
| Formats allowed to read and write | JPEG/JPG, PNG (and its PNG8/24/32/48/64 aliases), GIF, WEBP, AVIF, HEIC/HEIF, BMP, ICO; nothing else |
| Delegates | none |
| Indirect file reads (`@file` paths) | denied |
| `width` / `height` | 16 KP each. These are the hard rejection for oversized images |
| `memory` + `map` + `disk` | together **at most 512 MiB** per operation (§6b C1). The split is the builder's |
| `area` | the builder's, consistent with the row above. In ImageMagick 7, `area` is the point where the pixel cache spills from memory to disk; it is not a rejection limit |
| `time` | 120 s |
| `thread` | 1 |
| `list-length` | 32 |

`map` and `disk` caches are files in `/tmp`, so on a tmpfs they are RAM as well. That's why the three are capped together.

What the tests must show:
- every allowed format round-trips through Imagick;
- MVG, MSL, SVG/MSVG, URL/HTTP/HTTPS/FTP, TEXT, PS/EPS/PDF/XPS, EPHEMERAL and LABEL are refused;
- **under the hardened flags with `--memory 1g`:**
  - thumbnailing a 24-megapixel JPEG (a typical phone photo) succeeds;
  - a PNG declaring 20000×20000 is rejected by the width/height limit;
  - a 16384×16384 PNG fails with ImageMagick's "cache resources exhausted" error within 10 s;
  - in neither failure case is anything killed for running out of memory (the container's OOM-kill count stays 0);
- GD is unaffected.

`docs/security.md` explains how an app re-enables a format, for example TIFF, with its own policy file.

### 7.9 Healthcheck

`HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --start-interval=2s --retries=3`.

In `fpm` mode the check curls `http://127.0.0.1:8081/fpm-ping` and expects `pong`. The other modes stay as in the prototype: `auto|fpm|http|tcp|heartbeat|none`, `HEALTHCHECK_URL`, and the heartbeat age limit.

Test: a web container becomes healthy within 15 s of start.

### 7.10 Security contract and runtime tests

**Production run settings.** These are documented in `docs/security.md`, used by every example's `compose.prod.yml`, and **the runtime suite runs under them**:

```
--read-only
--tmpfs /tmp:rw,noexec,nosuid,nodev,size=256m
--cap-drop ALL
--security-opt no-new-privileges
--pids-limit 256
--memory 1g
```

`--memory 1g` with a 256 MiB tmpfs matches the defaults of the examples' `app` services (§7.12).

**New runtime checks**, added to the prototype's 56:
- **No TCP listener on 9000**, and the FPM socket exists with mode 0660.
- **Status pages:**
  - `/fpm-status` and `/nginx-status` on 8080 don't return the status page;
  - they return 200 from inside the container on 8081;
  - a request from another container on the same network with `X-Forwarded-For: 127.0.0.1` to 8080 doesn't get the status page.
- **Compression and caching:**
  - no `Content-Encoding` on a dynamic response by default;
  - gzip with `NGINX_GZIP=1`;
  - `gzip_static` serves a `.gz` sibling;
  - `nginx -T` shows `keepalive_timeout 120s` and `open_file_cache`.
- **Access log:** no access-log lines by default; lines appear with `NGINX_ACCESS_LOG=main`.
- **Forwarded headers:** `X-Forwarded-Port: 443` gives PHP `SERVER_PORT=443`, and `X-Forwarded-Proto: https` gives `HTTPS=on`.
- **Worker counts:**
  - exactly 2 nginx worker processes by default;
  - `FPM_MAX_CHILDREN=auto` under the hardened flags gives the formula's value (7) and logs its line;
  - an explicit number wins.
- **s6 behaviour** (§7.4 items 1–5):
  - graceful stop with an in-flight `sleep` request;
  - killing php-fpm → container exit ≠ 0 within 5 s;
  - a `WORKER_COMMAND` that exits after 1 s gets restarted;
  - all processes run as `www-data`, and PID 1 is tini.
- **ImageMagick:** the matrix in §7.8.
- **`PHP_DISABLE_FUNCTIONS=exec,shell_exec`:** `exec()` fails in a web request and works in `php -r` (CLI).
- **Contents:**
  - no `python3`;
  - no `composer`, `/usr/src/php.tar.xz` or `/usr/local/include` in the runtime image;
  - no setuid/setgid files.
- **Size:** every runtime image is at or under its line's `max_size_mb` (§6b C5).
- **Healthcheck:** healthy within 15 s.
- **Hooks** (§6b C2): a hook owned by `www-data` with mode 0555 triggers the warning, and refusal under `PHP_BASE_STRICT=1`. A root-owned hook with mode 0644 or 0755 runs with no warning.

**Dev checks**, added to the prototype's 8:
- composer, git and unzip are present;
- `apk add $PHPIZE_DEPS && docker-php-ext-install calendar`, run as root in a throwaway container, succeeds and loads;
- Xdebug turns on with `XDEBUG_MODE=debug`;
- PCOV turns on with `PHP_INI_EXTRA=pcov.enabled=1`, or the dev equivalent.

**Framework smoke tests:** as in the prototype (`test/frameworks/`), adjusted to v2:
- the socket, the internal listener, no `pgrep`;
- scheduler commands run through `php-base-every`.

They run on the lines listed in `versions.json`. A framework's value can be a list (§6b C4). The matrix:

| Line | Laravel | Drupal | WordPress | Moodle |
|---|---|---|---|---|
| 8.2 | ^12 | — | latest | 5.1 |
| 8.3 | ^12, ^13 | ^11 | latest | 5.2, 5.3 |
| 8.4 | ^12, ^13 | ^11 | latest | 5.1, 5.2, 5.3 |
| 8.5 | ^12, ^13 | ^11 | latest | — (Moodle doesn't support 8.5) |

The examples' line, 8.4, therefore tests everything the examples offer.

### 7.11 CI and automation

**`build-base.yml`**, built from the prototype, with these changes:

1. **The resolver also returns `ALPINE_IMAGE`.** It reads the Alpine minor from inside the PHP image and resolves `alpine:<minor>` to its digest.
2. **Guard rails** (§6 item 2):
   - php.net data comes from `https://www.php.net/releases/?json&version=X.Y`;
   - Alpine data comes from `https://alpinelinux.org/releases.json`;
   - the prototype's warning for a Docker Hub `last_updated` older than 30 days stays;
   - **new** warning: a GA tag appears for a pre-release line (e.g. `php:8.6-fpm-alpine` exists while `versions.json` still says `"prerelease": true`);
   - **new** warning: php.net supports a branch that `versions.json` doesn't list;
   - a failing guard fails **that line only**;
   - warnings go into the job summary.

   The resolver also picks the unique build tag (§7.2), and reads `max_size_mb` and the framework lists (§6b C4, C5) from `versions.json`.
3. **Tags** follow §6 item 22, with no `-alpine` tags. **Labels** follow §7.2.
4. **Test jobs run the hardened suite** (§7.10) and the size check. The job summary reports every image's size.
5. **Unchanged from the prototype:**
   - native amd64/arm64 runners;
   - push by digest, pull that digest back and test it;
   - publish per line with `imagetools create`;
   - cosign keyless signing, provenance `mode=max`, SBOM;
   - Trivy HIGH/CRITICAL ignore-unfixed as a hard gate;
   - actions pinned by SHA;
   - an issue opened when a scheduled run fails;
   - `workflow_dispatch` inputs: `only`, `publish`, `include_eol`, `skip_frameworks`.

**`watch-upstream.yml`:**
- cron `17 */6 * * *`;
- for each non-EOL line, a rebuild is triggered by any of three conditions (§6b C3):
  - the upstream PHP digest differs from the published `X.Y`'s `…upstream-digest` label;
  - the current `alpine:<minor>` digest differs from its `org.opencontainers.image.base.digest` label;
  - `apk upgrade --simulate`, run inside the published `X.Y` as root, would upgrade anything;
- it dispatches `build-base.yml -f only=<changed lines> -f publish=true`;
- the job summary says which condition fired for each line.

**`lint.yml`** runs on every push and PR:
- hadolint on every Dockerfile, base and examples;
- shellcheck on every shell script, including the examples';
- actionlint;
- `docker compose config -q` for every example compose file, using its `.env.example`;
- the Traefik example's `scripts/check-config.sh`;
- `scripts/check-links.sh`;
- the Cloudflare ranges check.

**Renovate** (`renovate.json`, this repo):
- PECL versions through the prototype's regex manager: **automerge minor/patch** after green CI, then the next build picks them up;
- GitHub Actions digests: automerge;
- image references inside `examples/` (Postgres, MariaDB, Traefik, socket proxy): PRs, no automerge.

### 7.12 App examples (`examples/laravel`, `drupal`, `wordpress`, `moodle`)

**Common contract.** Every example is a complete set of files to copy into a project.

| File | Purpose |
|---|---|
| `README.md` | copy steps, first deploy, choosing the certificate resolver, pinning digests, Renovate |
| `Dockerfile` | see below |
| `.dockerignore`, `.hadolint.yaml` | |
| `compose.yml` | local development: target `dev`, bind mount, port 8080, `PHP_OPCACHE_VALIDATE_TIMESTAMPS=1`, Xdebug off unless `XDEBUG_MODE` is set |
| `compose.prod.yml` | production behind Traefik; see below |
| `.env.example` | every setting below, documented; `TRAEFIK_CERT_RESOLVER` explains when to use `letsencrypt` (DNS not on Cloudflare; the domain must point straight at the VPS; port 80 must be open) |
| `docker/…` | only what the framework needs beyond the base presets: hooks, a config file such as `wp-config.php` or Moodle's `config.php`, optional `server.d` snippets |
| `.github/workflows/build-app.yml` | build; boot it and assert a real 200; Trivy; push |
| `renovate.json` | keeps both base digests current, plus other images |

**The Dockerfile:**
- Two arguments, each pinned by digest:
  - `PHP_BASE_IMAGE=docker.io/achelesstech/php-base:8.4@sha256:<runtime>`
  - `PHP_BASE_DEV_IMAGE=docker.io/achelesstech/php-base:8.4-dev@sha256:<dev>`

  The README shows how to get the two digests. A tag-only reference must still build, and is used in CI lint.
- **Build stages.** A build stage `FROM ${PHP_BASE_DEV_IMAGE}` runs `composer install`. Laravel adds a Node stage for Vite assets; Node never reaches the final image.
- **Production stage, `FROM ${PHP_BASE_IMAGE}`:**
  - **code is root-owned**;
  - only the framework's writable paths belong to `www-data`;
  - the matching preset is symlinked into `/etc/nginx/conf.d/` (an own vhost only when the preset can't do the job);
  - hooks are copied root-owned;
  - `RUN nginx-validate.sh`.
- **`dev` target:** `FROM ${PHP_BASE_DEV_IMAGE}`, with no `pecl install`.

**`compose.prod.yml` services:**
- `app`: web role;
- `queue`, where the framework has one: worker role via `command:`;
- `scheduler`: `command: [php-base-every, "60", …]`;
- `migrate`, under `profiles: [ops]`;
- the database.

**Hardening in `compose.prod.yml`:**
- `read_only`;
- `tmpfs: /tmp`, sized for the example's upload limit: at least 2 × `post_max_size` + 32 MB. The default is 256 MB for Laravel, Drupal and WordPress. Moodle uses a named volume on `/tmp` instead, documented;
- `cap_drop: [ALL]`;
- `security_opt: [no-new-privileges:true]`;
- `pids_limit`;
- `mem_limit`, sized together with the tmpfs (§6b C1):
  - `app`: 1g, or 2g for Moodle;
  - `queue` and `scheduler`: 512m;
  - each README explains the relation with `FPM_MAX_CHILDREN=auto`;
- `stop_grace_period`.

There are no `ports:` and no `pgrep` healthchecks.

**Traefik labels:**
- router name from `${TRAEFIK_ROUTER}`;
- `Host(\`${APP_DOMAIN}\`)`;
- `entrypoints=websecure`;
- `tls.certresolver=${TRAEFIK_CERT_RESOLVER:-cloudflare}`;
- `middlewares=chain-web@file`;
- service port 8080;
- `traefik.docker.network=proxy`.

**Registry for app images.** Docker Hub, `docker.io/achelesstech/<app>`, kept from the baseline. The image name is one variable at the top of `build-app.yml` and of `compose.prod.yml`. The README warns that app images contain the owner's code and must be **private**: Docker Hub's free plan allows only one private repository, and GHCR is the documented alternative.

**Per-example specifics:**

| Example | Base | Specifics |
|---|---|---|
| `laravel` | 8.4 | Laravel 13 (`laravel/laravel:^13.0`; one constraint changes it to 12). Preset `laravel.conf`. Framework caches baked at build time, as in the current template. Volume `storage/app`. Queue: `php artisan queue:work --max-time=3600`. Scheduler: `php artisan schedule:run` through `php-base-every`. `HEALTHCHECK_URL=http://127.0.0.1:8080/up` |
| `drupal` | 8.4 | `drupal/recommended-project:^11`. Preset `drupal.conf`. Env-driven `settings.php`, with `trusted_host_patterns` from `APP_DOMAIN` and no reverse-proxy settings, because nginx already sets `REMOTE_ADDR`. Volumes for public and private files. Scheduler: `vendor/bin/drush cron` |
| `wordpress` | 8.4 | A deployment repo: the core version is downloaded at build. Preset `wordpress.conf`. Env-driven `wp-config.php` with `DISALLOW_FILE_MODS=true` (code is immutable) and `DISABLE_WP_CRON=true`. Scheduler: `wp cron event run --due-now`. Volume `wp-content/uploads`. MariaDB 11.4 |
| `moodle` | 8.4 | A deployment repo, `MOODLE_503_STABLE`; one line switches it to `MOODLE_502_STABLE`. Preset `moodle.conf` (`public/` layout). Env-driven `config.php` with `$CFG->getremoteaddrconf = 3`. Volume moodledata. `NGINX_FASTCGI_READ_TIMEOUT=600s` and `FPM_REQUEST_TERMINATE_TIMEOUT=600s`. Upload limits documented. Scheduler: `php public/admin/cli/cron.php`. PostgreSQL 18. The old template's `MOODLE_RUN_CRON` hook, which wrote supervisor config, is gone |

The prototype's `test/frameworks/*/Dockerfile` files are proven working references for each framework's build steps.

### 7.13 Traefik example (`examples/traefik`)

The owner's host setup, which is already hardened and audited, is kept as it is, with these improvements:

1. **Certificates.**
   - Both resolvers stay: `cloudflare` (DNS-01, default on `websecure`) and `letsencrypt` (HTTP-01).
   - Comments and docs state the rule from §6 item 23, and that a non-Cloudflare site **must** set `letsencrypt` on its router, because the default resolver can only issue for Cloudflare zones.
   - The stale claim that Let's Encrypt emails expiry warnings is corrected.
   - `make certs` (`acme-certs.sh`) and `make doctor` flag certificates expiring within **21 days** and exit non-zero.
   - `docs/reverse-proxy.md` mentions the Prometheus metric `traefik_tls_certs_not_after` for alerting.
2. **Backend transport.** The static config sets `serversTransport.forwardingTimeouts.idleConnTimeout: 90s` explicitly, with a comment: backends must keep connections longer, and php-base uses 120 s.
3. **Docker socket proxy.**
   - Replace `tecnativa/docker-socket-proxy:0.3.0` with **`wollomatic/socket-proxy`**: the latest 1.x at implementation time, pinned by tag and digest, with a read-only root, non-root, `cap_drop: [ALL]`, and an allowlist of only the GET endpoints Traefik uses (version, ping, containers, events, networks).
   - **Verify locally:** boot Traefik against it with `scripts/check-config.sh`, then start a labelled container and confirm Traefik routes it and drops it on stop.
   - If that verification fails, keep tecnativa, bump it to its latest release, and record why in the compose comments.
4. **Traefik version.** Move to the newest v3 minor that exists at implementation time, but only if its release notes show no breaking change for this config and `scripts/check-config.sh` passes. Otherwise stay on v3.6. Either way, pin by tag and digest.
5. **Docs** (`docs/traefik/labels.md`, `vps-setup.md`):
   - Traefik routes only to containers Docker reports as healthy, which is why `start-interval` matters;
   - nginx inside php-base no longer compresses;
   - when to attach the existing `retry` middleware (connection refused during deploys);
   - the cert-resolver rule;
   - Docker ≥ 25.

Everything else stays as it is: the middlewares, TLS options, trusted IPs, timeouts, logging and dashboard protection.

### 7.14 Portainer example

Moved to `examples/portainer/`, with the router's resolver from `${PORTAINER_CERT_RESOLVER:-cloudflare}`. No other changes.

### 7.15 Documentation

**`README.md`** (root) is short:
- what the image is and which frameworks it supports;
- the tag table with examples (e.g. `achelesstech/php-base:8.4`, `:8.4.27`, `:8.4.27-20261026`, `:8.4-dev`, `:latest`);
- a quick start;
- links into `docs/`.

**Pages under `docs/`** (purposes as listed in §7.1):
- `docs/image.md` holds the complete env-variable reference. It covers every existing `PHP_*`, `FPM_*`, `NGINX_*`, `HEALTHCHECK_*` and scheduler/worker variable from the prototype's entrypoint, plus the new ones:
  - `NGINX_WORKER_PROCESSES`, `NGINX_GZIP`, `NGINX_FASTCGI_READ_TIMEOUT`;
  - `FPM_MAX_CHILDREN=auto`, `FPM_WORKER_MEMORY`, `FPM_REQUEST_TERMINATE_TIMEOUT` (new default);
  - `PHP_DISABLE_FUNCTIONS`;
  - the new `NGINX_ACCESS_LOG` default.
- `docs/migrating-from-v1.md` lists every breaking change:
  - CMD `php-base-web` instead of supervisord;
  - no `/etc/supervisor`;
  - FPM on a socket;
  - status paths only on 8081;
  - composer only in `-dev`;
  - no PHP sources in runtime;
  - the access log off by default;
  - no dynamic gzip;
  - `pgrep` healthchecks replaced by role-aware ones.

  It also recommends copying hooks root-owned. That isn't a breaking change: anything else only warns (§6b C2).

  It also gives the FarmBook/HQ steps from the prototype's `PROPOSAL.md` §7.
- **`CHANGELOG.md`** gets a **v2** entry that lists the breaking changes.

### 7.16 Definition of done

**On this machine (amd64):**
1. An Opus 5.5 subagent at medium effort builds all eight images as `local/php-base:{8.2,8.3,8.4,8.5}[-dev]`.
2. `test/run.sh` (hardened) and `test/run-dev.sh` pass on all four lines.
3. The framework tests pass for every pair in `versions.json`.
4. Trivy finds 0 fixable HIGH/CRITICAL on all eight images.
5. Every runtime image is at or under its `max_size_mb`, and every size is reported.
6. Lint is clean: hadolint, shellcheck, actionlint, `docker compose config` on every example, the Traefik `check-config.sh`, and the link check.
7. The Traefik socket-proxy routing test passes (§7.13 item 3).
8. No leftover test containers, networks or volumes. Cleanup uses labels and `docker rm -f -v`.

**Not verifiable here.** Reported as such; the first CI run after the owner pushes covers them:
- arm64;
- publishing to Docker Hub;
- cosign signing;
- scheduled and watcher runs.

### 7.17 Left to the builder

- s6 mechanics and file names (§7.4).
- Script internals and the structure of the test helpers.
- The exact `policy.xml` text, within §7.8.
- CI job layout, within §7.11.
- The wording of the docs.
- Any value this document doesn't fix.

Where the prototype already solves something and this document doesn't change it, **keep the prototype's solution**. It was verified.
