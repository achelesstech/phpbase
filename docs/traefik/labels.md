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
| `…routers.<n>.tls.certresolver` | always on websecure | `cloudflare` (DNS-01, wildcards) or `letsencrypt` (HTTP-01) |
| `…routers.<n>.middlewares` | strongly | without it there is no HSTS, no rate limit, no header stripping |
| `…routers.<n>.tls.options=modern@file` | optional | TLS 1.3 only; for APIs and admin tools |
| `…routers.<n>.priority` | rarely | only to beat another router on the same path |

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
| `chain-web@file` | public web apps — rate limit + security headers + compression |
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

Queue workers, schedulers, Moodle cron and one-shot `ops` jobs must **not**
carry Traefik labels. They run no nginx. They also cannot pass the `php-base`
healthcheck, which curls `/fpm-ping`:

```yaml
  queue:
    command: ["php", "artisan", "queue:work"]
    networks: [internal]          # not proxy
    # no labels
    healthcheck:
      test: ["CMD-SHELL", "pgrep -f 'queue:work' >/dev/null || exit 1"]
```

Every template in [`examples/`](../../examples/) already does this.

## Health, and why Traefik does not need to know about it

Traefik will not route to a container that is not running, but by default it
does not read Docker's health status — a container that is `unhealthy` still
receives traffic. Two options, and the first is usually enough:

```yaml
# 1. Let the orchestrator restart it. php-base already exits the container when
#    php-fpm or nginx dies, so an unhealthy container becomes a stopped one.
restart: unless-stopped

# 2. Traefik-side health check, for when you run replicas
- traefik.http.services.lms.loadbalancer.healthcheck.path=/fpm-ping
- traefik.http.services.lms.loadbalancer.healthcheck.interval=10s
- traefik.http.services.lms.loadbalancer.healthcheck.timeout=3s
```

`/fpm-ping` is the right target because it goes through FastCGI. A static nginx
`return 200` stays green while PHP-FPM is dead.

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
- **Upload size** — nginx `client_max_body_size` in the app's vhost and
  `PHP_UPLOAD_MAX_FILESIZE`. Cloudflare's edge cap (100 MB on Free/Pro) sits
  above both and wins.

## Worked example — Moodle behind Cloudflare

```yaml
services:
  app:
    image: docker.io/achelesstech/moodle52:latest
    restart: unless-stopped
    networks: [proxy, internal]
    environment:
      MOODLE_URL: https://lms.example.com
      MOODLE_SSLPROXY: "true"        # mandatory, or infinite redirect loop
      PHP_UPLOAD_MAX_FILESIZE: 512M
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

  cron:
    image: docker.io/achelesstech/moodle52:latest
    command: ["moodle-cron.sh"]
    networks: [internal]
    # no labels — no nginx, no route
    healthcheck:
      test: ["CMD-SHELL", "pgrep -f moodle-cron >/dev/null || exit 1"]

networks:
  proxy:
    external: true
  internal:
```

Note `lms-login` needs an explicit `.service=lms`: a router only gets the
container's service implicitly when it is the *only* router on it.

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
