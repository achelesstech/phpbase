# Running behind Traefik and Cloudflare

Every app built on `php-base` is a backend. It listens on plain HTTP `:8080`,
publishes no ports, and never terminates TLS. The chain is:

```
client ──TLS──► Cloudflare ──TLS──► Traefik ──plain HTTP──► nginx ──► php-fpm
                (edge)              (origin)                    :8080
```

Two proxies means two places to get forwarded headers right, and a mistake in
either shows up as a vague application bug rather than a proxy error.

---

## What the image already does

| Concern | Handled by | Where |
|---|---|---|
| Client IP | `set_real_ip_from` RFC1918 + `real_ip_recursive on` | base `nginx.conf` |
| Scheme | `map $http_x_forwarded_proto → $fcgi_https` | base `nginx.conf` |
| Scheme → PHP | `fastcgi_param HTTPS $fcgi_https if_not_empty` | each app vhost |

So inside PHP, `$_SERVER['REMOTE_ADDR']` is the real client and
`$_SERVER['HTTPS']` is `'on'` only when the request really was HTTPS.

**This is only as trustworthy as Traefik.** nginx trusts `X-Forwarded-For` from
anything on the private Docker network. Traefik is what stands between that and
the internet, so Traefik must overwrite XFF for untrusted sources. If it does
not, a client can forge `X-Forwarded-For: 1.2.3.4` and defeat every rate limit,
login throttle and IP ban in every app.

---

## Traefik: the two settings that matter

### 1. Trust Cloudflare, and nothing else

Static config:

```yaml
entryPoints:
  websecure:
    address: ":443"
    forwardedHeaders:
      # ONLY these sources may set X-Forwarded-*. Everything else has the
      # headers overwritten with the real connection values.
      trustedIPs:
        # Cloudflare IPv4 — https://www.cloudflare.com/ips-v4
        - 173.245.48.0/20
        - 103.21.244.0/22
        - 103.22.200.0/22
        - 103.31.4.0/22
        - 141.101.64.0/18
        - 108.162.192.0/18
        - 190.93.240.0/20
        - 188.114.96.0/20
        - 197.234.240.0/22
        - 198.41.128.0/17
        - 162.158.0.0/15
        - 104.16.0.0/13
        - 104.24.0.0/14
        - 172.64.0.0/13
        - 131.0.72.0/22
        # Cloudflare IPv6 — https://www.cloudflare.com/ips-v6
        - "2400:cb00::/32"
        - "2606:4700::/32"
        - "2803:f800::/32"
        - "2405:b500::/32"
        - "2405:8100::/32"
        - "2a06:98c0::/29"
        - "2c0f:f248::/32"
```

Verify this list against cloudflare.com/ips before deploying — it changes.

If you leave `trustedIPs` unset, Traefik appends to whatever XFF the client
sent, and nginx's `real_ip_recursive` will happily walk back to the forged
value.

### 2. Only accept connections from Cloudflare

`trustedIPs` fixes header spoofing but the origin is still directly reachable
if someone finds its IP. Add an IP allowlist middleware, or better, use a
Cloudflare Tunnel so the origin has no inbound ports at all.

```yaml
http:
  middlewares:
    cloudflare-only:
      ipAllowList:
        sourceRange:
          - 173.245.48.0/20
          # … same list as above
```

Attach it to every router in front of these apps.

---

## Cloudflare: five things that will bite you

### 1. SSL mode must be Full (strict)

**Flexible** means Cloudflare speaks HTTPS to the browser and **HTTP** to
Traefik. Your app sees `X-Forwarded-Proto: http`, generates `http://` URLs,
Cloudflare rewrites to `https://`, and you get an infinite redirect loop — the
classic "too many redirects" that looks like an app bug. Use **Full (strict)**
with a real certificate on Traefik.

### 2. Upload size is capped at the edge

| Plan | Max request body |
|---|---|
| Free | 100 MB |
| Pro | 100 MB |
| Business | 200 MB |
| Enterprise | 500 MB (raisable) |

**This matters most for Moodle**, whose course backups and assignment
submissions routinely exceed 100 MB. The template sets
`PHP_UPLOAD_MAX_FILESIZE=512M` and `client_max_body_size 512m`, which
Cloudflare will happily override with a 413 the app never sees.

Options: keep uploads under the cap, put large-file paths on a
`grey-clouded` (DNS-only) subdomain that bypasses Cloudflare, or use a tunnel.

### 3. The 100-second timeout (error 524)

Cloudflare terminates any request that takes longer than 100 s on non-Enterprise
plans. Moodle upgrades, large restores and Drupal `updatedb` all exceed this.

The templates already avoid the problem — upgrades and migrations are one-shot
CLI services, not web requests:

```bash
docker compose -f compose.prod.yml --profile ops run --rm upgrade   # Moodle
docker compose -f compose.prod.yml --profile ops run --rm migrate   # Laravel
```

Never run `/admin/index.php` upgrades or `update.php` through the browser
behind Cloudflare.

### 4. Caching will serve logged-in pages to strangers

Cloudflare does not cache HTML by default, but a "Cache Everything" page rule
absolutely will, and it does not know about your session cookie. Serving one
user's dashboard to another is the failure mode.

If you enable Cache Everything, add a bypass for the session cookies:

| App | Cookie |
|---|---|
| Moodle | `MoodleSession*` |
| Drupal | `SSESS*`, `SESS*` |
| WordPress | `wordpress_logged_in_*`, `wp-settings-*`, `comment_*` |
| Laravel | your `SESSION_COOKIE`, plus `laravel_session` |

Also bypass `/admin*`, `/login*`, `/user*`, `/wp-admin*` and anything POST.

### 5. Cloudflare's real-IP header is not X-Forwarded-For

Cloudflare sends `CF-Connecting-IP` and *also* prepends to `X-Forwarded-For`.
This stack uses `X-Forwarded-For` throughout, which works. Do not add
`CF-Connecting-IP` handling to nginx as well — two sources of truth for client
IP is how you end up trusting the wrong one.

---

## Per-application notes

### Moodle

```php
$CFG->wwwroot  = 'https://lms.example.com';   // exact, no trailing slash
$CFG->sslproxy = true;                        // MANDATORY behind TLS termination
```

The entrypoint writes both from `MOODLE_URL` and `MOODLE_SSLPROXY`. Getting
`sslproxy` wrong is an infinite redirect loop, not an error message.

Run the built-in diagnostic if anything looks off:

```bash
docker compose exec app moodle-doctor.sh
```

### Drupal

`$settings['reverse_proxy']` and the trusted-header bitmask are appended to
`settings.php` by the entrypoint. Set `DRUPAL_REVERSE_PROXY_ADDRESSES` if your
Docker networks are not RFC1918.

Also set `trusted_host_patterns` — with a proxy in front, Drupal cannot infer
its own hostname safely.

### Laravel

nginx fixes `REMOTE_ADDR`, but Laravel still needs trusted proxies for scheme
and host. In `bootstrap/app.php`:

```php
->withMiddleware(function (Middleware $middleware) {
    $middleware->trustProxies(at: [
        '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16',
    ]);
})
```

Set `APP_URL` to the public HTTPS URL, and make sure `ASSET_URL` matches, or
mixed-content warnings follow.

### WordPress

`WP_HOME` and `WP_SITEURL` are set from `WORDPRESS_URL` by the entrypoint. Both
must be the exact public URL with scheme, or WordPress redirect-loops.

---

## Verifying the chain

From outside, with the site live:

```bash
# Should be your real IP, not a 172.x address
curl -s https://your-site.example.com/ -H 'Accept: text/plain' -o /dev/null -w '%{http_code}\n'
```

From inside the container:

```bash
# Real client IP arriving at PHP
docker compose exec app sh -c \
  'curl -s -H "X-Forwarded-For: 203.0.113.9" http://127.0.0.1:8080/ >/dev/null; \
   tail -1 /dev/null'

# Confirm nginx sees forwarded headers correctly
docker compose logs app | tail -20
```

Then check the application's own view: Moodle's *Site administration →
Reports → Config changes* shows client IPs; Drupal's *Recent log messages*
shows hostnames; a stream of `172.18.0.x` in either means the chain is broken.

### Spoofing check

This must **not** change the recorded client IP when sent from the internet:

```bash
curl -s https://your-site.example.com/ -H 'X-Forwarded-For: 1.2.3.4'
```

If your logs show `1.2.3.4`, Traefik's `forwardedHeaders.trustedIPs` is not set
and every IP-based control in every app is bypassable.
