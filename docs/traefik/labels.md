# Traefik labels — reference for application repositories

How a `php-base` application publishes itself. Nothing is registered on the
Traefik side: the container declares its own route, Traefik's Docker provider
sees it via the events stream, and the route exists about a second later.

Everything here goes in the app's own `compose.prod.yml`.

---

## The minimum

```yaml
services:
  app:
    image: docker.io/achelesstech/lms:latest
    networks: [proxy, internal]
    labels:
      - traefik.enable=true
      - traefik.docker.network=proxy
      - traefik.http.services.lms.loadbalancer.server.port=8080
      - traefik.http.routers.lms.rule=Host(`lms.example.com`)
      - traefik.http.routers.lms.entrypoints=websecure
      - traefik.http.routers.lms.tls.certresolver=cloudflare
      - traefik.http.routers.lms.middlewares=chain-web@file
```

No `ports:`. Publishing a port alongside a Traefik route gives you a second
entrance with no TLS, no HSTS, no rate limit and no auth — and `make doctor`
flags it.

## How a label is built

```
traefik . http . routers . <name> . <property> = <value>
   │       │        │         │
   │       │        │         └─ yours. Any string. It is the identity of the
   │       │        │            route, and it must be unique across the HOST,
   │       │        │            not just this compose file.
   │       │        └─ routers | services | middlewares
   │       └─ http | tcp | udp
   └─ always
```

`<name>` collisions are the most common self-inflicted outage on a host running
several stacks: two projects both using `app` silently merge into one router
whose properties are whichever container Traefik saw last. Name it after the
site (`lms`, `intranet-drupal`, `acme-wp`), never after the compose service.

Property names are case-insensitive, so `entrypoints` and `entryPoints` both
work. Pick one and stay consistent.

## Required and optional

| Label | Needed | Notes |
|---|---|---|
| `traefik.enable=true` | **always** | `exposedByDefault` is false |
| `traefik.docker.network=proxy` | when on >1 network | which network Traefik dials. Omit it on a multi-homed container and Traefik may pick `internal`, which it cannot reach — a 502 with a healthy backend |
| `…services.<n>.loadbalancer.server.port=8080` | **always here** | `php-base` listens on 8080. Traefik guesses only from `EXPOSE`, and guesses wrong when there is more than one |
| `…routers.<n>.rule` | **always** | see below |
| `…routers.<n>.entrypoints=websecure` | **always** | omit it and the router is attached to *every* entryPoint, including `ping` and `metrics` |
| `…routers.<n>.tls.certresolver` | always on websecure | `cloudflare` if the domain's DNS is on Cloudflare, otherwise `letsencrypt` — see [below](#which-certificate-resolver) |
| `…routers.<n>.middlewares` | strongly | without it there is no HSTS, no rate limit, no header stripping |
| `…routers.<n>.tls.options=modern@file` | optional | TLS 1.3 only; for APIs and admin tools |
| `…routers.<n>.priority` | rarely | only to beat another router on the same path |

## Which certificate resolver

One rule, decided by where the domain's **DNS** is hosted, not where it was
registered:

| The domain's DNS is on | Label | Challenge |
|---|---|---|
| Cloudflare | `tls.certresolver=cloudflare` | DNS-01 through the Cloudflare API token |
| anywhere else — Namecheap, GoDaddy, a local registrar, your own DNS | `tls.certresolver=letsencrypt` | HTTP-01 on `:80` |

`cloudflare` is the `websecure` default, so a router that omits the label gets
it. It can only issue for zones the Cloudflare token can edit. A site whose DNS
is anywhere else **must** set `letsencrypt` explicitly; otherwise the
certificate never issues, the Traefik log shows a DNS-01 error for a zone the
token cannot see, and browsers get a TLS handshake failure.

```yaml
# DNS on Cloudflare
- traefik.http.routers.lms.tls.certresolver=cloudflare

# DNS at Namecheap, GoDaddy, a local registrar, ...
- traefik.http.routers.shop.tls.certresolver=letsencrypt
```

HTTP-01 needs the domain's `A` record pointing at this host and `:80` reachable
from the internet before Traefik first sees the router, and it cannot issue
wildcards. The `:80 → :443` redirect does not get in its way.

Both resolvers fail quietly: an issuance that keeps failing leaves the old
certificate in place until it expires. Let's Encrypt no longer emails expiry
warnings, so `make certs` and `make doctor` (in `examples/traefik/`) exit
non-zero when a certificate expires within 21 days. Run one from cron, or
alert on the Prometheus metric `traefik_tls_certs_not_after`.

## Rules

```yaml
- traefik.http.routers.lms.rule=Host(`lms.example.com`)

# Several names on one route
- traefik.http.routers.lms.rule=Host(`lms.example.com`) || Host(`www.lms.example.com`)

# A subtree
- traefik.http.routers.api.rule=Host(`app.example.com`) && PathPrefix(`/api`)

# Everything except a subtree — v3 syntax; v2's `!` on a bare matcher is gone
- traefik.http.routers.web.rule=Host(`app.example.com`) && !PathPrefix(`/api`)
```

Backticks, not quotes. Traefik v3 renamed several v2 matchers
(`Path` → `PathPrefix`/`Path`, `Headers` → `Header`); a v2 rule pasted into v3
fails to parse and the router simply never appears, with one line in the log.

**Two routers on the same host, different paths:** equal `priority` means the
longer rule wins, so `Host && PathPrefix(/api)` already beats bare `Host`. Set
`priority` only when the rules are the same length.

## Middlewares

Reference the shared ones from
[`config/dynamic/middlewares.yml`](../../examples/traefik/config/dynamic/middlewares.yml)
with **`@file`**:

```yaml
- traefik.http.routers.lms.middlewares=chain-web@file
- traefik.http.routers.lms.middlewares=chain-web@file,noindex@file
```

Without `@file` Traefik looks for a middleware defined by labels on this
container, does not find it, and the router never becomes healthy — it returns
404 for every request while `docker ps` shows everything up.

Available (see that file for what each does):

| Name | For |
|---|---|
| `chain-web@file` | public web apps — rate limit + security headers + compression (see below) |
| `chain-api@file` | JSON APIs — adds CORS, no CSP |
| `chain-admin@file` | basic auth + strict rate limit |
| `chain-admin-restricted@file` | the above + client-IP allowlist |
| `csp-strict@file` | opt-in CSP. Test in a browser first — it breaks CMS editors |
| `noindex@file` | staging and admin: `X-Robots-Tag: noindex` |
| `ratelimit-login@file` | put on `/login` paths specifically |
| `ipallowlist-admin@file` | edit its `sourceRange` before use |
| `ipallowlist-cloudflare-edge@file` | refuse anything not from Cloudflare |
| `redirect-to-apex@file` | `www.` → apex |

Order is execution order, left to right on the request.

**Compression happens here, not in the app.** nginx inside `php-base` no longer
compresses dynamic responses (`NGINX_GZIP=0` by default); it only serves
pre-compressed `.gz` files that already exist. The `compress` middleware in
`chain-web` and `chain-api` is what compresses HTML and JSON, so a router that
uses neither chain serves them uncompressed. Do not turn `NGINX_GZIP` back on
behind Traefik: compressing twice costs CPU on both sides and gains nothing.

### `retry@file` — for connection refused during deploys

When a deploy replaces a container, Traefik can for a moment still send
requests to the address of the one that is stopping. Those fail as
`connection refused`, which the client sees as a 502. The shared `retry`
middleware retries such a request up to 3 times, starting 100 ms apart, and
only when the backend sent no response at all:

```yaml
- traefik.http.routers.lms.middlewares=chain-web@file,retry@file
```

Put it **last**, so a retry replays only the call to the backend and not the
rate limit. Attach it when you see brief 502s while deploying. Leave it off
routers that take payments or other POSTs that must never run twice: a
connection that dies after the app received the request but before it
answered is retried too.

### Defining one locally

Fine for something specific to this app:

```yaml
- traefik.http.middlewares.lms-bigbody.buffering.maxRequestBodyBytes=0
- traefik.http.routers.lms.middlewares=chain-web@file,lms-bigbody
```

A locally defined middleware needs no suffix from the same container (or
`lms-bigbody@docker` from elsewhere). Its name is host-global too.

### `$` in labels

```yaml
# WRONG — compose expands ${1} to an empty string before Traefik sees it
- traefik.http.middlewares.r.redirectregex.replacement=https://${1}

# RIGHT — $$ escapes to a literal $
- traefik.http.middlewares.r.redirectregex.replacement=https://$${1}
```

The symptom is a redirect to `https://` with nothing after it, i.e. a loop.
In `dynamic/*.yml` files there is no compose interpolation, so `${1}` is
correct there — the same expression is written differently in the two places.

## Worker containers

Queue workers, schedulers and one-shot `ops` jobs must **not** carry Traefik
labels and don't join the `proxy` network. They run no nginx, so there is
nothing to route to. They need no `healthcheck:` either: the `php-base`
healthcheck picks its probe from the container's command.

| Container | `command:` | Health |
|---|---|---|
| web | the default (`php-base-web`) | `fpm`: `/fpm-ping` through PHP-FPM, on the internal `127.0.0.1:8081` listener, plus `HEALTHCHECK_URL` if set |
| scheduler | `php-base-every 60 …` | `heartbeat`: the last successful run is recent |
| queue worker, anything else | e.g. `php artisan queue:work` | `none`: always healthy |

```yaml
  queue:
    command: [php, artisan, queue:work, --max-time=3600]
    networks: [internal]          # not proxy
    # no labels, no healthcheck override

  scheduler:
    command: [php-base-every, "60", php, artisan, schedule:run]
    networks: [internal]
```

Don't add `pgrep` checks: they show that a process exists, not that it
works, and the image's own check is better for both roles. Every app
template in [`examples/`](../../examples/) follows this.

## Health: Traefik routes only to healthy containers

Traefik's Docker provider skips any container whose healthcheck status is not
`healthy`. A container that is still `starting`, or has turned `unhealthy`,
gets no traffic until it reports healthy. That is what keeps a deploy from
sending requests to an app that is still booting.

It is also why `start-interval` matters. `php-base` declares

```
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --start-interval=2s --retries=3
```

During the start period Docker probes every 2 s instead of every 30 s, so a
new container is `healthy`, and routed, a few seconds after nginx and PHP-FPM
are up. Without `start-interval`, the first probe would come 30 s after
start, and the site would have no backend for those 30 s on every deploy.

`--start-interval` needs **Docker Engine 25 or later**. Check with
`docker version`. Older engines ignore it and fall back to the 30 s interval.

Two consequences:

- **Do not override the healthcheck with something slower** in the app's
  compose file, and do not disable it: with no healthcheck at all, Traefik
  routes as soon as the container starts, before PHP-FPM is ready.
- **A container that stays unhealthy simply drops out of the route.** With one
  replica the router disappears and the whole site returns 404, so
  `restart: unless-stopped` still matters: `php-base` exits when php-fpm or
  nginx dies, and Docker restarts it.

A Traefik-side health check is only worth adding when you run replicas and
want Traefik to stop using one faster than Docker's 30 s interval notices:

```yaml
- traefik.http.services.lms.loadbalancer.healthcheck.path=/up
- traefik.http.services.lms.loadbalancer.healthcheck.interval=10s
- traefik.http.services.lms.loadbalancer.healthcheck.timeout=3s
```

Point it at a path the app answers through PHP (Laravel's `/up`, for example).
A static file stays green while PHP-FPM is dead. `php-base`'s own status paths
are on its internal `127.0.0.1:8081` listener, which Traefik cannot reach.

## Replicas and sessions

```yaml
- traefik.http.services.lms.loadbalancer.sticky.cookie=true
- traefik.http.services.lms.loadbalancer.sticky.cookie.name=lb
- traefik.http.services.lms.loadbalancer.sticky.cookie.secure=true
- traefik.http.services.lms.loadbalancer.sticky.cookie.httponly=true
- traefik.http.services.lms.loadbalancer.sticky.cookie.samesite=lax
```

Sticky cookies are a workaround, not a fix. Before scaling past one replica,
move PHP sessions to Redis — `php-base` exposes `PHP_SESSION_SAVE_HANDLER` and
`PHP_SESSION_SAVE_PATH` for exactly this. With disk sessions and no stickiness,
users are logged out at random; with stickiness, they are logged out whenever a
container is replaced.

## Things that are not labels

- **`passHostHeader`** — on by default for the Docker provider, so the backend
  sees the original `Host`. Do not turn it off: every PHP application builds
  absolute URLs from it.
- **`X-Forwarded-Proto`** — Traefik sets it. `php-base`'s nginx maps it to
  `HTTPS=on` for PHP. Nothing to add.
- **Client IP** — Traefik's `forwardedHeaders.trustedIPs` (static config) plus
  nginx's `real_ip` module (in `php-base`) already deliver the real
  `REMOTE_ADDR`. Do not add `CF-Connecting-IP` handling on top; two sources of
  truth for the client IP is how you end up trusting the wrong one.
- **HTTP/3** — advertised by the entryPoint for every router.
- **Upload size** — `PHP_UPLOAD_MAX_FILESIZE` and `PHP_POST_MAX_SIZE`;
  nginx's `client_max_body_size` follows `post_max_size`. Cloudflare's edge
  cap (100 MB on Free/Pro) sits above both and wins.

## Worked example — Moodle behind Cloudflare

Cut down from [`examples/moodle/compose.prod.yml`](../../examples/moodle/compose.prod.yml),
with a tighter rate limit on the login form added:

```yaml
services:
  app:
    image: docker.io/achelesstech/moodle-app:latest   # your private app image
    restart: unless-stopped
    networks: [proxy, internal]
    environment:
      MOODLE_WWWROOT: https://lms.example.com   # config.php turns on sslproxy for https
      PHP_UPLOAD_MAX_FILESIZE: 512M
      PHP_POST_MAX_SIZE: 512M                   # nginx's body limit follows it
    labels:
      - traefik.enable=true
      - traefik.docker.network=proxy
      - traefik.http.services.lms.loadbalancer.server.port=8080

      # main site
      - traefik.http.routers.lms.rule=Host(`lms.example.com`)
      - traefik.http.routers.lms.entrypoints=websecure
      - traefik.http.routers.lms.tls.certresolver=cloudflare
      - traefik.http.routers.lms.middlewares=chain-web@file

      # tighter limit on the login form only. Longer rule, so it already wins.
      - traefik.http.routers.lms-login.rule=Host(`lms.example.com`) && PathPrefix(`/login`)
      - traefik.http.routers.lms-login.entrypoints=websecure
      - traefik.http.routers.lms-login.tls.certresolver=cloudflare
      - traefik.http.routers.lms-login.middlewares=ratelimit-login@file,chain-web@file
      - traefik.http.routers.lms-login.service=lms

  scheduler:
    image: docker.io/achelesstech/moodle-app:latest
    command: [php-base-every, "60", php, admin/cli/cron.php, --keep-alive=0]
    networks: [internal]
    # no labels: no nginx, no route. Health is the php-base-every heartbeat.

networks:
  proxy:
    external: true
  internal:
```

Note `lms-login` needs an explicit `.service=lms`: a router only gets the
container's service implicitly when it is the *only* router on it. The real
file also sets the hardening flags, `mem_limit`, `/tmp` and the database.

## When a route does not work

```bash
docker compose logs --tail=50 traefik | grep -i error   # in examples/traefik/
docker inspect <container> --format '{{json .Config.Labels}}' | python3 -m json.tool
```

Then, in order of how often it is the cause:

| Symptom | Cause |
|---|---|
| 404 on every request | missing `@file` on a middleware, or a v2 rule syntax that failed to parse |
| 502, container healthy | wrong `loadbalancer.server.port`, or missing `traefik.docker.network` |
| 404 and the router is absent from the dashboard | `traefik.enable` missing, or the container is not on the `proxy` network |
| route works, then breaks when another stack deploys | duplicate router or service `<name>` |
| redirect loop | `X-Forwarded-Proto` not reaching the app, or Cloudflare SSL mode is Flexible |
| redirect to bare `https://` | `${1}` instead of `$${1}` in a label |
| TLS handshake failure, no HTTP error | `sniStrict` — the client sent no SNI, or you used the IP |
| every site on `:443` dead, container healthy | a `tls.options` name that does not resolve — the log says `unknown TLS options: …`. `default` is applied automatically and must **not** be written `default@file` |
| cert never issues | DNS-01 token scope, or `make doctor` on the token file |
