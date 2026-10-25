# Running behind Traefik and Cloudflare

Every app built on `php-base` is a backend. It listens on plain HTTP `:8080`,
publishes no ports, and never terminates TLS:

```
client ──TLS──► Cloudflare ──TLS──► Traefik ──plain HTTP──► nginx ──unix socket──► php-fpm
                (edge, optional)    (origin)                  :8080
```

There are two proxies, so forwarded headers have to be right in two places.
A mistake in either looks like an application bug, not a proxy error. This
page covers the parts that cross the boundary between the image and the
proxy. The proxy itself is in [`examples/traefik/`](../examples/traefik/),
with its own docs in [`traefik/`](traefik/).

- [What the image already does](#what-the-image-already-does)
- [Traefik: trust Cloudflare, and nothing else](#traefik-trust-cloudflare-and-nothing-else)
- [Keep-alive: nginx 120s, Traefik 90s](#keep-alive-nginx-120s-traefik-90s)
- [Compression happens in Traefik](#compression-happens-in-traefik)
- [Timeouts, uploads and the `/tmp` tmpfs](#timeouts-uploads-and-the-tmp-tmpfs)
- [Certificates: which resolver](#certificates-which-resolver)
- [Health: Traefik routes only to healthy containers](#health-traefik-routes-only-to-healthy-containers)
- [Cloudflare: five things that will bite you](#cloudflare-five-things-that-will-bite-you)
- [Per-application notes](#per-application-notes)
- [Verifying the chain](#verifying-the-chain)

## What the image already does

| PHP sees | From | Set by |
|---|---|---|
| `REMOTE_ADDR` = the visitor | `X-Forwarded-For`, trusted only from the private ranges and Cloudflare's edge, with `real_ip_recursive on`. Loopback is never trusted | rendered at start from `NGINX_REAL_IP_FROM` and `NGINX_TRUST_CLOUDFLARE` |
| `HTTPS=on` only for an HTTPS request | `X-Forwarded-Proto: https` | `fastcgi-php.conf` (`if_not_empty`, so plain HTTP has no `HTTPS` at all) |
| `SERVER_PORT` = 443 | `X-Forwarded-Port`, when it is a plain number | `fastcgi-php.conf` |
| `Host` | the original host; Traefik passes it through | — |

So no app needs "trusted proxy" settings for the client address, scheme or
port. The variables are in [`image.md`](image.md#nginx).

**This is only as trustworthy as Traefik.** nginx believes `X-Forwarded-For`
from anything on the private Docker network. Traefik is what stands between
that and the internet, so Traefik must overwrite the header for untrusted
sources. If it doesn't, a client can send `X-Forwarded-For: 1.2.3.4` and
defeat every rate limit, login throttle and IP ban in every app.

## Traefik: trust Cloudflare, and nothing else

**1. `forwardedHeaders.trustedIPs` on every entryPoint lists Cloudflare's
ranges, IPv4 and IPv6, and nothing else.** Traefik then overwrites
`X-Forwarded-For` for every other source. Left unset, Traefik appends to
whatever the client sent, and nginx's `real_ip_recursive` walks back to the
forged value. The list is in
[`examples/traefik/config/traefik.yml`](../examples/traefik/config/traefik.yml);
why each part is there is in
[`traefik/static-config.md`](traefik/static-config.md#forwardedheaderstrustedips--the-important-one).
Cloudflare adds ranges from time to time, and nothing logs an error when the
list goes stale. `make cf-ips` in `examples/traefik/` compares it with the
live list. The base image's own copy (for `NGINX_TRUST_CLOUDFLARE`) is compared
by `scripts/update-cloudflare-ips.sh --check` on every CI run, which reports a
difference without failing.

**2. Accept connections only from Cloudflare.** `trustedIPs` stops header
spoofing, but the origin can still be reached directly if someone finds its
IP. Attach `ipallowlist-cloudflare-edge@file` to the router (see
[`traefik/labels.md`](traefik/labels.md#middlewares)), or use a Cloudflare
Tunnel so the origin has no inbound ports at all.

## Keep-alive: nginx 120s, Traefik 90s

Traefik keeps idle connections to a backend open for reuse for
`serversTransport.forwardingTimeouts.idleConnTimeout`: **90s**, set
explicitly in the example's `traefik.yml`. nginx in php-base keeps them for
`keepalive_timeout` **120s**, with `keepalive_requests 10000`.

The order matters. If the backend closed first, Traefik could send a request
down a connection nginx is closing at that moment, and the client would get a
502 that no app log records. With 120s against 90s, Traefik always closes
first. If you raise Traefik's value, keep it below 120s. If you put another
proxy in front of php-base, give it an idle timeout under 120s too.

## Compression happens in Traefik

nginx in php-base doesn't compress dynamic responses (`NGINX_GZIP=0`). It
still serves pre-compressed `.gz` files with `gzip_static`. The `compress`
middleware in `chain-web@file` and `chain-api@file` compresses HTML and JSON,
so a router that uses neither chain serves them uncompressed. Don't set
`NGINX_GZIP=1` behind Traefik: compressing twice costs CPU and gains nothing.
Turn it on only when nothing in front compresses.

## Timeouts, uploads and the `/tmp` tmpfs

**Timeouts nest.** Each layer gives up before the one outside it, so the
error comes from the layer that knows why:

```
PHP max_execution_time  ≤  FPM_REQUEST_TERMINATE_TIMEOUT  ≤  NGINX_FASTCGI_READ_TIMEOUT  ≤  Traefik readTimeout
        120                       300s                              300s                       600s (websecure)
```

Traefik's `readTimeout` covers reading the whole request body. Its default is
60s, which kills a large upload on a slow line with no error in any app log.
The example raises it to 600s on `websecure`
([`traefik/static-config.md`](traefik/static-config.md#transportrespondingtimeouts)).
The Moodle example raises all three inner limits (PHP, PHP-FPM and nginx)
to 600s for backups and restores, matching Traefik's `readTimeout`.

**Uploads go to `/tmp`, and a tmpfs is RAM.** nginx buffers the request body
in `/tmp/php-base/nginx/tmp/` and PHP writes the uploaded file to `/tmp`, so
both copies exist at once. On a tmpfs, both count against the container's
memory limit. So:

- **Always give the tmpfs a size**:
  `/tmp:rw,noexec,nosuid,nodev,size=256m`. An unsized tmpfs may grow to half
  the host's RAM, and `FPM_MAX_CHILDREN=auto` reserves its full size. With the
  default memory limits that leaves only 2 workers
  ([`image.md`](image.md#php-fpm-workers-fpm_max_childrenauto)).
- **Size it at least 2 × `post_max_size` + 32 MB.** 256 MB fits the default
  64M; the Laravel, Drupal and WordPress examples use that.
- **For large uploads, put `/tmp` on a volume instead.** The Moodle example
  takes 512M uploads, which would need over 1 GB of tmpfs, so its `app`
  container mounts a named volume on `/tmp`.

nginx's `client_max_body_size` follows PHP's `post_max_size`, so raising
`PHP_UPLOAD_MAX_FILESIZE` and `PHP_POST_MAX_SIZE` is enough on the
php-base side. Cloudflare has its own cap ([below](#2-upload-size-is-capped-at-the-edge)).

## Certificates: which resolver

The Traefik example has two certificate resolvers. Pick one per router, by
where the domain's **DNS** is hosted, not where it was registered:

| The domain's DNS is on | `tls.certresolver` | Challenge |
|---|---|---|
| Cloudflare | `cloudflare` (the `websecure` default) | DNS-01 through the Cloudflare API token |
| anywhere else: Namecheap, GoDaddy, a local registrar, your own DNS | `letsencrypt` | HTTP-01 on `:80` |

Every app example reads it from `TRAEFIK_CERT_RESOLVER` in `.env`. A domain
whose DNS isn't on Cloudflare **must** set `letsencrypt`. Left on the
`cloudflare` default, its certificate never issues: the Traefik log shows a
DNS-01 error and browsers get a TLS handshake failure. For `letsencrypt`, the
domain's `A` record must point straight at the VPS (no proxy or CDN in front),
and `:80` must be open to the internet before Traefik first sees the router.
More in [`traefik/labels.md`](traefik/labels.md#which-certificate-resolver).

**Expiry.** A renewal that keeps failing is silent: the old certificate stays
in place until it expires, and Let's Encrypt no longer emails expiry
warnings. `make certs` and `make doctor` in `examples/traefik/` exit non-zero
when a certificate expires within 21 days; run one from root's crontab
([`traefik/vps-setup.md`](traefik/vps-setup.md#8-ongoing)). If you scrape
Traefik's Prometheus metrics (the `metrics` entryPoint, reachable only from
the `proxy` network), alert on **`traefik_tls_certs_not_after`**, the expiry
time of each certificate as a Unix timestamp:

```promql
traefik_tls_certs_not_after - time() < 21 * 24 * 3600
```

## Health: Traefik routes only to healthy containers

Traefik's Docker provider skips a container until Docker reports it
`healthy`. php-base probes every 2 s while a container starts
(`--start-interval`, Docker 25+), so a new container gets traffic within
seconds. The web check goes through PHP-FPM on the internal `127.0.0.1:8081`
listener, which Traefik can't reach. See
[`traefik/labels.md`](traefik/labels.md#health-traefik-routes-only-to-healthy-containers)
and [`image.md`](image.md#healthcheck).

## Cloudflare: five things that will bite you

### 1. SSL mode must be Full (strict)

**Flexible** means Cloudflare speaks HTTPS to the browser and plain HTTP to
Traefik. The app sees `X-Forwarded-Proto: http` and builds `http://` URLs,
and you get an endless redirect loop ("too many redirects") that looks like
an app bug. Use **Full (strict)**, with a real certificate on Traefik.

### 2. Upload size is capped at the edge

| Plan | Max request body |
|---|---|
| Free | 100 MB |
| Pro | 100 MB |
| Business | 200 MB |
| Enterprise | 500 MB (can be raised) |

This matters most for Moodle, whose course backups and assignment
submissions often exceed 100 MB. The Moodle example allows 512M uploads, but
Cloudflare answers anything over its cap with a 413 the app never sees.
Options: keep uploads under the cap, serve large-upload paths from a
DNS-only (grey-cloud) host name that bypasses Cloudflare, or use a tunnel.

### 3. The 100-second timeout (error 524)

Cloudflare ends any request that takes longer than 100 s on non-Enterprise
plans. Moodle upgrades, large restores and Drupal database updates take
longer. The examples run them as one-shot CLI services, not web requests:

```bash
docker compose -f compose.prod.yml run --rm migrate   # Laravel, Drupal, Moodle
```

Never run `/admin/index.php` upgrades or `update.php` through the browser
behind Cloudflare.

### 4. Caching will serve logged-in pages to strangers

Cloudflare doesn't cache HTML by default, but a "Cache Everything" rule will,
and it doesn't know about your session cookie. One user's dashboard is then
served to another. If you enable Cache Everything, bypass the cache for the
session cookies:

| App | Cookie |
|---|---|
| Moodle | `MoodleSession*` |
| Drupal | `SSESS*`, `SESS*` |
| WordPress | `wordpress_logged_in_*`, `wp-settings-*`, `comment_*` |
| Laravel | your `SESSION_COOKIE`, or `laravel_session` |

Also bypass `/admin*`, `/login*`, `/user*`, `/wp-admin*` and anything POST.

### 5. Cloudflare's real-IP header is not X-Forwarded-For

Cloudflare sends `CF-Connecting-IP`, and also adds the visitor to
`X-Forwarded-For`. This stack uses `X-Forwarded-For` throughout, which works.
Don't add `CF-Connecting-IP` handling in nginx or the app as well: with two
sources for the client IP, you end up trusting the wrong one.

## Per-application notes

What each example sets, and why nothing more is needed.

### Moodle

`config.php` in [`examples/moodle/`](../examples/moodle/) sets:

```php
$CFG->wwwroot  = rtrim($env('MOODLE_WWWROOT'), '/');   // https://${APP_DOMAIN}
$CFG->sslproxy = str_starts_with($CFG->wwwroot, 'https://');
$CFG->getremoteaddrconf = 3;
```

- **`sslproxy`.** Traefik terminates TLS. Without `sslproxy`, an https
  wwwroot gives an endless redirect loop and no error message.
- **`getremoteaddrconf = 3`.** Moodle can take the client address from the
  `X-Forwarded-For` or `Client-IP` headers, which nginx passes on to PHP as
  the client sent them. That would let a client pick the address Moodle logs,
  rate-limits and locks out. 3 skips both headers, so Moodle uses only
  `REMOTE_ADDR`, which nginx has already set to the visitor, trusting only
  Traefik's network and Cloudflare's edge. Being in `config.php`, it overrides
  the admin setting.

### Drupal

`settings.php` has **no** reverse-proxy settings: `REMOTE_ADDR`, `HTTPS`
and the port already arrive correct, so there is nothing for them to fix. It
sets `trusted_host_patterns` from `APP_DOMAIN`, so any other `Host` gets a
400.

### Laravel

No `trustProxies()` call is needed: Symfony's request reads the scheme from
`HTTPS` and the client from `REMOTE_ADDR` when no proxy is trusted. Set
`APP_URL` to the public HTTPS URL (the example uses
`https://${APP_DOMAIN}`). Rate limiting by IP then sees real visitors.

### WordPress

`wp-config.php` sets `WP_HOME` and `WP_SITEURL` from `WORDPRESS_URL`, which
must be the exact public URL, scheme included, or WordPress redirect-loops.
`is_ssl()` is right without any proxy code, because nginx passes `HTTPS=on`.
A plugin that reads `X-Forwarded-For` itself skips all of this: when a
security plugin asks how to find the visitor's IP, choose `REMOTE_ADDR`.

## Verifying the chain

`make doctor` in `examples/traefik/` checks the forwarded-header config, TLS
and certificates. Run its script with a site URL and it also does a live
spoofing test: it sends a forged `X-Forwarded-For` and checks that Traefik's
access log did not record the forged address as the client.

```bash
./scripts/traefik-doctor.sh https://lms.example.com   # in examples/traefik/
```

Run it against the **public** URL. A request to `127.0.0.1` never passes
through Cloudflare or the trust decision, so it passes however wrong the
config is.

To see what the app receives, turn the access log on for a moment
(`NGINX_ACCESS_LOG=main`; its first field is the client address nginx
settled on) and send a forged header from outside:

```bash
curl -s -o /dev/null https://your-site.example.com/ -H 'X-Forwarded-For: 1.2.3.4'
docker compose -f compose.prod.yml logs --tail=5 app
```

The first field must be your own public address, never `1.2.3.4` and never a
`172.x` Docker address. `1.2.3.4` means Traefik's `trustedIPs` isn't set, and
every IP-based control in every app can be bypassed. A `172.x` address means
nginx doesn't trust the Traefik network: check `NGINX_REAL_IP_FROM`.
