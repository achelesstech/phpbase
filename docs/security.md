# Security

What the image defends against, how to run it, and what the tests prove. The
image's contents and settings are in [`image.md`](image.md).

- [Threat model](#threat-model)
- [The hardened run flags](#the-hardened-run-flags)
- [What the tests prove](#what-the-tests-prove)
- [The ImageMagick policy](#the-imagemagick-policy)
- [Shipping your own ImageMagick policy](#shipping-your-own-imagemagick-policy)

## Threat model

The image runs PHP applications on a VPS behind Traefik, next to other
containers on a shared Docker network. The most likely attack is **code
execution inside PHP**: a vulnerable plugin, an unsafe upload handler, a
deserialisation bug. The image assumes that will happen one day and limits
what the attacker gets.

| Threat | What the image does |
|---|---|
| **Code execution as `www-data`** | Nothing runs as root: PID 1 is tini, every other process is `www-data`. No setuid or setgid file exists. With `--cap-drop ALL` and `no-new-privileges`, the process can't gain privileges either |
| **Persistence across a restart** | The root filesystem is read-only. Config, presets, scripts, s6 service definitions and (by the documented pattern) the app's code and hooks are root-owned. The only writable place, `/tmp`, holds the rendered config in `/tmp/php-base`, which the entrypoint wipes before PHP or nginx reads it again: an `.ini` with `auto_prepend_file` planted there never loads |
| **A hook as a backdoor** | Hooks run at every start. One that isn't root-owned, or is writable by group or others, logs a warning; with `PHP_BASE_STRICT=1` the container refuses to start |
| **Neighbours on the Docker network** | PHP-FPM listens only on a Unix socket, so no other container can send it FastCGI requests (with FastCGI, a client can set `PHP_VALUE` and run arbitrary code). The status pages are on `127.0.0.1:8081`, not behind an ACL on the public port: nginx trusts `X-Forwarded-For` from the private ranges, so `allow 127.0.0.1` on 8080 could be passed by any container sending `X-Forwarded-For: 127.0.0.1` |
| **Spoofed client IPs** | `X-Forwarded-For` is trusted only from private ranges and Cloudflare's edge, never from loopback. It is only as good as Traefik's own `forwardedHeaders.trustedIPs`; see [`reverse-proxy.md`](reverse-proxy.md) |
| **Malicious uploads** | Only `.php` files execute (`security.limit_extensions`); the Laravel preset executes only `index.php`. ImageMagick reads and writes an allowlist of raster formats, with no delegates and no scripting coders, and a capped budget per operation (below) |
| **Resource exhaustion** | `--pids-limit` stops fork bombs; `--memory` bounds the container. The FPM pool is sized from that limit, and the ImageMagick caps make a decompression bomb fail with an error instead of an OOM kill |
| **Stale or tampered images** | Every build starts from digests resolved at build time, upgrades every Alpine package, and must pass Trivy (no fixable HIGH/CRITICAL finding). The digest CI tested is the digest it publishes, signed with cosign and carrying an SBOM and provenance. A watcher rebuilds within about 6 hours of a new upstream PHP image, a new Alpine image, or a pending Alpine package update |
| **Leaky defaults** | `expose_php=Off`, `server_tokens off`, errors logged rather than displayed, `zend.exception_ignore_args=On` so stack traces carry no arguments, secure session cookies, and `session.upload_progress` off |

**What it does not defend against:**
- **Bugs in the application.** A SQL injection or broken access check is the
  app's problem. The image limits what an attacker can do next; it can't stop
  the first step.
- **Secrets in the environment.** `clear_env = no` passes the container's
  environment to PHP, because every supported framework is configured that
  way. Code running in PHP can read every variable the container has, so give
  each container only the secrets it needs.
- **The app's writable paths.** `storage/`, `wp-content/uploads`, moodledata
  and the like are writable and persistent by design. Keep them out of
  anything that executes; the presets do.
- **PHP reading files from `/tmp`.** `noexec` on `/tmp` stops a dropped binary
  from running, but PHP can still `include` a file from there. That is why the
  config PHP reads from `/tmp/php-base` is rendered fresh at every start.
- **The kernel and the container runtime.** A container escape is out of
  scope; keep the host patched.

## The hardened run flags

Run the runtime image with these flags. The runtime test suite runs every
check under them.

```
--read-only
--tmpfs /tmp:rw,noexec,nosuid,nodev,size=256m
--cap-drop ALL
--security-opt no-new-privileges
--pids-limit 256
--memory 1g
```

| Flag | Why |
|---|---|
| `--read-only` | Nothing outside `/tmp` (and the app's own volumes) can change, so nothing a compromised process writes there survives a restart |
| `--tmpfs /tmp:…,size=256m` | The one writable place. `noexec,nosuid,nodev` stop binaries, setuid files and device nodes there. **`size=` is required**: an unsized tmpfs may grow to half the host's RAM, and `FPM_MAX_CHILDREN=auto` reserves all of it, so it falls back to 2 workers unless the memory limit is well above half the host's RAM (about half the RAM + 448 MiB with the defaults; [`image.md`](image.md#php-fpm-workers-fpm_max_childrenauto)). 256 MB fits the default 64M uploads; use at least 2 × `post_max_size` + 32 MB, or a volume |
| `--cap-drop ALL` | Every process is `www-data` and needs no capability: the ports are above 1024 and nothing changes user |
| `--security-opt no-new-privileges` | No process can gain privileges through execve, whatever is on disk |
| `--pids-limit 256` | A fork bomb hits a ceiling instead of the host |
| `--memory 1g` | Bounds the container. The FPM pool, the tmpfs and the ImageMagick caps are sized against it |

In compose:

```yaml
services:
  app:
    image: docker.io/achelesstech/<app>@sha256:…
    read_only: true
    tmpfs:
      - /tmp:rw,noexec,nosuid,nodev,size=256m
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    pids_limit: 256
    mem_limit: 1g
    stop_grace_period: 60s
```

`stop_grace_period` must cover the shutdown, or Docker kills what is still
running. nginx drains first (killed after 15 s at most), then php-fpm stops
(30 s at most), so a web container needs about 45 s; 60 s leaves a margin. One that runs
`SCHEDULER_COMMAND` or `WORKER_COMMAND` can take up to 120 s for those after
nginx has stopped: give it about 140 s.

## What the tests prove

Every runtime check below runs against a fixture app built on the image and
started with the hardened flags. The checks exist because each one was
actually broken once, in this image or an app built on it, or because the
docs promise it.

**At build time** (`Dockerfile`), the build fails unless:
- every extension loads without a warning, and `php -v` runs;
- the nginx and FPM configuration validates;
- the runtime's Alpine is the same minor the PHP binaries were built on, and
  the PHP version is the line's;
- nothing is owned by the deleted upstream uid/gid 82, and no setuid or setgid
  file exists;
- Python, supervisord, Composer, PHP sources and headers, PEAR/PECL,
  `phpize`, `php-cgi` and `phpdbg` are absent from the runtime (and Composer
  present in -dev).

**Runtime suite** (`test/run.sh`, sections in `test/runtime/`):

| Section | What it proves |
|---|---|
| `boot` | The fixture becomes healthy within 15 s under the hardened flags, through `/fpm-ping` on 8081, which means FPM answers, not only nginx |
| `identity` | PHP executes through FastCGI on the expected line; the user is 1000:1000; `$HOME` exists and is writable; nothing is owned by uid/gid 82; `php-base-info` reports the running PHP |
| `config` | `PHP_*` overrides apply, including a value with `?`, `&` and `=`; `PHP_INI_EXTRA` applies; an explicit `FPM_MAX_CHILDREN` wins; a hook without the exec bit still runs |
| `defaults` | The production ini defaults are in force: assertions off, exception arguments hidden, `request_order=GP`, upload progress off, `max_input_vars ≥ 5000`, JIT off |
| `extensions` | All expected extensions load; argon2id hashing, GNU iconv `//TRANSLIT`, full ICU data, Imagick's and GD's image formats, phpredis with igbinary/zstd/lz4, memcached with igbinary |
| `imagemagick` | The policy ([below](#the-imagemagick-policy)): every allowed format round-trips; MSL, MVG, SVG, MSVG, HTTPS, TEXT, PS, EPS, PDF, XPS, EPHEMERAL and LABEL are refused; a 24-megapixel JPEG thumbnails; a 20000×20000 image is rejected by the width/height limit; a 16384×16384 PNG fails with "cache resources exhausted" within 10 s; nothing is OOM-killed (`oom_kill 0`); GD is unaffected |
| `proxy` | `HTTPS` is unset on plain HTTP and `on` with `X-Forwarded-Proto: https`; `REMOTE_ADDR` is the client across a multi-hop private chain and a Cloudflare hop; `X-Forwarded-For` over loopback is ignored; `NGINX_TRUST_CLOUDFLARE=0` stops at the Cloudflare hop |
| `nginx` | Bad env values are refused by name; 2 nginx workers by default and `NGINX_WORKER_PROCESSES` changes it; keep-alive 120 s/10000, `open_file_cache` and `gzip_static` are on; no dynamic gzip by default, gzip with `NGINX_GZIP=1`; no access log by default, `main` and `json` with `NGINX_ACCESS_LOG`; `X-Forwarded-Port: 443` gives `SERVER_PORT=443`; the FastCGI read timeout is rendered and no preset overrides it; a 60 MiB POST fits the 256 MB tmpfs with no "No space left" |
| `status` | `/fpm-status` and `/nginx-status` on 8080 are not the status pages; on `127.0.0.1:8081` they are, and `/fpm-ping` answers `pong`; `X-Forwarded-For: 127.0.0.1` from another container doesn't reach the FPM status; 8081 is unreachable from the network; the `HEALTHCHECK` parameters are as documented, and a new container is healthy within 15 s |
| `limits` | nginx's body limit follows `PHP_POST_MAX_SIZE` (413 above, 200 below); `FPM_SLOWLOG_TIMEOUT` works and its traces reach the log |
| `fpm` | Nothing listens on TCP 9000; the socket is `/tmp/php-base/php-fpm.sock`, 0660, `www-data`; `request_terminate_timeout` is 300s; `security.limit_extensions = .php`; `FPM_MAX_CHILDREN=auto` gives 7 under the hardened flags and logs why, 12 without a memory limit, 11 with a volume on `/tmp`, and counts `PHP_OPCACHE_MEMORY`; `FPM_MAX_CHILDREN=08` is refused; `PHP_DISABLE_FUNCTIONS` disables `exec()` in web requests and leaves the CLI alone |
| `hardening` | Config, preset, s6, hook and bin directories aren't writable by `www-data`; `$HOME`'s target is 0750; nginx writes no log files and raises no alerts; the FPM socket is the only socket under `/tmp`; a v1 `supervisord` command fails and names `php-base-web`; an `.ini` planted in `/tmp/php-base` is wiped at restart and never loads; writable and non-root-owned hooks warn, and `PHP_BASE_STRICT=1` refuses them; a root-owned 0644 hook, directly or through a symlink, runs without a warning |
| `contents` | No build tooling, sources or Composer; no setuid/setgid files; the labels name the right Alpine base, upstream image and digest, PHP and Alpine versions and variant; PID 1 is tini and every process is uid 1000; no Python or supervisor tree; `error_log()` reaches `docker logs`; the image is within its line's size ceiling |
| `jobs` | `SCHEDULER_COMMAND` runs in the web container; a `php-base-every` container is healthy by heartbeat, and turns unhealthy when its job keeps failing; another worker command is not falsely unhealthy; `php-base-every` stops promptly on SIGTERM; `WORKER_COMMAND` restarts when it exits and keeps quoted arguments intact |
| `lifecycle` | `docker stop` lets an in-flight request finish with 200 and exits 0; killing php-fpm or nginx takes the container down within 5 s with a non-zero exit |

**Dev suite** (`test/run-dev.sh`): Xdebug and PCOV are loaded but off, and
turn on when asked (`XDEBUG_MODE`, `pcov.enabled=1`); assertions are on and
OPcache revalidates; Composer, git and unzip run; `docker-php-ext-install`
builds and enables an extension; `PHPIZE_DEPS` matches upstream; the variant
label and `php-base-info` say dev.

**Framework smoke tests** (`test/frameworks/`) install real Laravel, Drupal,
WordPress and Moodle on every line and version `versions.json` lists, and
check that they serve.

**In CI** as well: Trivy finds no fixable HIGH/CRITICAL vulnerability, and the
digest that passed every test is the one published.

## The ImageMagick policy

ImageMagick has a long history of vulnerabilities in its less common coders
(MVG, MSL, SVG, PostScript through ghostscript, URL fetching). Alpine's own
`policy.xml` permits everything. This image replaces it with
`/etc/ImageMagick-7/policy.xml`, root-owned, which works as an allowlist and a
per-operation budget. `magick -list policy` inside a container prints it.

**Formats.** Every coder is denied, then these are allowed:

| Allowed | Read | Write |
|---|---|---|
| JPEG/JPG, PNG (and its PNG8/24/32/48/64 write aliases), GIF, WEBP, AVIF, BMP, ICO | yes | yes |
| HEIC/HEIF | yes | **no**, in practice |

HEIC is read-only even though the policy allows writing it: Alpine's libheif
decodes HEVC (through libde265) but ships no HEVC encoder. Reading is what
matters: WordPress converts iPhone HEIC uploads to JPEG.

SVG, PS, EPS and PDF fail twice over: the policy denies them, and their coders
(Alpine's `imagemagick-svg` and `imagemagick-pdf`) aren't installed. Depending on the
format and how it is named, ImageMagick reports "not authorized" (the policy)
or "no decode delegate" (no coder).

**Also denied:**
- **all delegates** (`domain="delegate"`): ImageMagick never runs an external
  program, not ghostscript, not curl;
- **indirect reads** (`@file` paths), which would splice a file's contents
  into an argument.

**Resource caps, per operation:**

| Resource | Value | Why |
|---|---|---|
| `width`, `height` | 16KiP (16384 px) each | the hard rejection for oversized images: wider or taller fails with "width or height exceeds limit" |
| `memory` | 384MiB | the heap pixel cache. Holds a 24-megapixel phone photo (about 275 MiB as RGB, 366 MiB as RGBA in this Q16-HDRI build) |
| `map` | 64MiB | memory-mapped cache files |
| `disk` | 64MiB | cache files on disk, which means `/tmp`, which on a tmpfs is RAM too |
| `area` | 32MP | above this many pixels the cache goes to a file even if memory would fit. ImageMagick 7 treats it as a spill point, not a rejection |
| `time` | 120 s | processing time budget per image |
| `thread` | 1 | PHP-FPM already runs one worker per request; threads inside each would oversubscribe the CPUs |
| `list-length` | 32 | frames per image sequence (animated GIF, multi-size ICO) |

`memory` + `map` + `disk` = 512 MiB. With `--memory 1g`, the worst image fails
with "cache resources exhausted" instead of getting a worker, or the whole
container, killed for running out of memory. The `imagemagick` test section
proves both the success and the failure cases.

GD isn't affected by any of this. It has no policy file; the PHP
`memory_limit` bounds it.

## Shipping your own ImageMagick policy

If an app needs a format the image doesn't allow (TIFF, say), ship a policy
file in the app image. Changing the allowlist takes two things: the coder must
be installed, and the policy must allow it.

1. Copy the image's policy into the app repository:

   ```sh
   docker run --rm --entrypoint cat docker.io/achelesstech/php-base:8.4 \
     /etc/ImageMagick-7/policy.xml > docker/imagemagick/policy.xml
   ```

2. Add the format names to the allowlist pattern, and nothing else:

   ```xml
   <policy domain="coder" rights="read|write" pattern="{JPEG,JPG,PNG,PNG8,PNG24,PNG32,PNG48,PNG64,GIF,WEBP,AVIF,HEIC,HEIF,BMP,ICO,TIFF,TIF}"/>
   ```

   Keep the deny-all coder rule above it, the delegate and `@*` path rules, and
   the resource caps. Coder names are case-sensitive.

3. Install the coder and copy the policy over the image's, root-owned and
   read-only:

   ```dockerfile
   FROM ${PHP_BASE_IMAGE}
   USER root
   RUN apk add --no-cache imagemagick-tiff
   COPY --chmod=0644 docker/imagemagick/policy.xml /etc/ImageMagick-7/policy.xml
   USER www-data
   ```

   `COPY` without `--chown` leaves the file owned by root, so a compromised
   PHP process can't loosen it.

4. Check the result:

   ```sh
   docker run --rm --entrypoint magick my-app -list policy
   docker run --rm --entrypoint magick my-app -list format | grep -i tiff
   ```

Large TIFFs (scans, print files) can exceed the 512 MiB budget. Raise
`memory` (and the container's memory limit with it) rather than `disk`: on a
tmpfs, disk is RAM as well. Allowing a format means trusting its decoder with
whatever users upload, so add only what the app needs.

When you rebase onto a new php-base digest, compare your copy with the image's
policy, so you pick up any changes to it.
