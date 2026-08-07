# Static configuration, property by property

`config/traefik.yml`. Read once at process start; a change needs
`make restart`. Everything that can be changed live is in `config/dynamic/`.

Two rules that explain most of the surprises:

1. **No variable expansion.** Traefik does not expand `${VAR}` in this file.
   An ACME email or a domain written as `${ACME_EMAIL}` is used *literally*.
   Passing it in through compose `environment:` does nothing — nothing reads it.
   (Traefik *can* be configured entirely by `TRAEFIK_*` environment variables
   instead of a file, but you cannot mix the two per-key.)
2. **Unknown keys are rejected.** A typo is a startup failure, not a warning.
   That is a feature. `make check` catches it before `make up`.
3. **CLI flags are ignored once `--configFile` is given.** Passing
   `--api.insecure=true` alongside a config file does nothing — no error, no
   listener. You cannot patch one setting from the command line for a quick
   test; edit a copy of the file instead. (Confirmed on 3.6.25 while building
   `make check`.)

---

## `global`

```yaml
global:
  checkNewVersion: false
  sendAnonymousUsage: false
```

Both are outbound calls from an edge process. Off. Version tracking belongs to
Renovate on the pinned image tag.

## `api`

```yaml
api:
  dashboard: true
  insecure: false
```

`insecure: true` serves the dashboard and the full API on `:8080` with **no
authentication**. It is the single most common Traefik misconfiguration, and
because `:8080` is often also published for convenience, it ends up on the
internet. Keep it `false`; the dashboard is reached through the router in
`compose.yml`, behind an IP allowlist and basic auth.

The dashboard is read-only, but it enumerates every route, service, middleware
and backend address you run. Treat it as sensitive.

## `ping`

```yaml
ping:
  entryPoint: ping
```

A `/ping` handler for the Docker healthcheck (`traefik healthcheck --ping`).
On its own entryPoint (`:8082`, unpublished) so it is never routable from
outside and never collides with an application route.

## `log` and `accessLog`

```yaml
log:
  level: INFO
  format: json
accessLog:
  format: json
  bufferingSize: 100
```

Both to stdout/stderr, no `filePath`. Files inside a container are invisible to
`docker logs`, grow in the writable layer, and require Traefik's own
`maxSize`/`maxBackups` rotation to be configured or they grow forever. With
stdout, the Docker logging driver in `compose.yml` rotates them and the same
command works on one host or a hundred.

`format: json` because these get parsed. `common` is unparseable once you add
header fields.

`bufferingSize: 100` buffers access-log lines in memory before writing. It
trades up to 100 lines on a hard kill for materially less write pressure at
load. Set it to `0` while debugging so lines appear immediately.

**No `filters.statusCodes`.** Filtering to `400-599` is tempting and costs you
the audit trail: a `200` that should have been a `403` is invisible, and
successful requests are where client IPs are verified. `make doctor`'s live
spoof test reads this log — with the filter on, it cannot see the probe.

Headers are `defaultMode: drop` with an explicit keep list. `Authorization` and
`Cookie` are dropped by name as well, so that adding a header to the keep list
later cannot accidentally start logging credentials. `CF-Connecting-IP` and
`CF-Ray` are kept because the first question in any client-IP problem is
whether Cloudflare is even in the path.

## `entryPoints`

A named socket. Nothing is served on one unless a router attaches to it — which
is why a router with no `entrypoints` label is a problem: it attaches to *all*
of them, including `ping` and `metrics`.

### `forwardedHeaders.trustedIPs` — the important one

```yaml
forwardedHeaders:
  trustedIPs: &trusted_proxies
    - "127.0.0.1/32"
    …
```

For a connection whose **peer address** is in this list, Traefik passes
`X-Forwarded-For` / `-Proto` / `-Host` through as received. For anything else it
**overwrites** them with the real connection values.

That overwrite is the entire security property. Leave the list empty and a
client can send `X-Forwarded-For: 1.2.3.4`; Traefik appends to it, nginx's
`real_ip_recursive` walks back to the forged value, and `REMOTE_ADDR` inside
PHP is whatever the attacker chose. Every rate limit, login throttle, IP ban
and audit log on the host is then decorative. There is no error and no warning.

Three things to get right:

- **Include Cloudflare IPv6.** If the origin has an `AAAA` record, Cloudflare
  will connect over v6. Miss those ranges and the edge is untrusted, so Traefik
  replaces `X-Forwarded-For` with Cloudflare's own address and every backend
  sees Cloudflare as the client — the same symptom as having no config at all,
  arrived at from the opposite direction.
- **Keep one list.** Both entryPoints need it. The YAML anchor
  (`&trusted_proxies` / `*trusted_proxies`) means there is one to maintain.
  Two copies drift, and the one that drifts is always the one you are not
  looking at.
- **Re-check it.** `make cf-ips`, in cron.

Including RFC1918 alongside Cloudflare is safe *because* ports are published in
host mode and nothing untrusted can open a connection from a private address.
On a host where arbitrary containers can reach Traefik, trim it.

### `transport.respondingTimeouts`

```yaml
readTimeout: 600s     # websecure
writeTimeout: 0
idleTimeout: 180s
```

`readTimeout` bounds reading the **whole request, body included**. Traefik's
default is 60s, which is wrong for this stack: a 200 MB Moodle backup on a
10 Mbit link needs about three minutes. It fails as a dead connection, with
nothing in the application log — the request never completed, so PHP never ran.

Raising it widens slowloris exposure. Cloudflare in front absorbs that. If you
ever run this origin bare, lower it and cap upload sizes instead.

`writeTimeout: 0` — no limit on writing the response, so a large download or a
streamed `pluginfile.php` is not cut off mid-flight.

`web` keeps 30s: it only issues redirects.

### `transport.lifeCycle`

```yaml
requestAcceptGraceTimeout: 5s
graceTimeout: 30s
```

On shutdown, keep accepting for 5s (so a load balancer notices the health
change first), then let in-flight requests finish for up to 30s. Without it,
`docker compose up -d` during an upload is a visible 502 for whoever was
uploading.

### `http.redirections` on `web`

```yaml
web:
  http:
    redirections:
      entryPoint:
        to: websecure
        scheme: https
        permanent: true
```

Nothing is served on `:80`. `permanent: true` sends 301 — cacheable, so
browsers stop asking. Traefik implements this as a very high priority router,
which is why you cannot override it per-site; it also does **not** break the
HTTP-01 ACME challenge, for which Traefik installs its own higher-priority
route.

### `http3`

```yaml
http3:
  advertisedPort: 443
```

Advertises HTTP/3 via `Alt-Svc`. Requires UDP/443 published — it is in
`compose.yml`. If the UDP port is missing, browsers try QUIC, fail, and fall
back to TCP, which is correct but adds a round trip to every first visit.

### `http.tls`

```yaml
tls:
  certResolver: cloudflare
```

The entryPoint default, so a router that omits `tls.certresolver` still gets a
certificate rather than failing. Per-router labels override it.

**No `options:` key here**, and this one is a trap worth knowing. The TLS option
set named `default` in `dynamic/tls.yml` is registered *without* a provider
suffix and is applied automatically to every router that does not choose one.
Writing `options: default@file` looks symmetrical with `modern@file` and is
wrong: Traefik logs

```
unknown TLS options: default@file
```

and then **fails to build every router on the entryPoint**. The container stays
healthy, `:443` stays open, and nothing is served. Named sets do take the
suffix, per router (`tls.options=modern@file`).

This was in the first draft of this file. `make check` did not catch it — the
error is per-router, so it only appears once a router exists — which is why the
verification below used a throwaway container with labels.

## `providers`

### `docker`

```yaml
endpoint: "tcp://socket-proxy:2375"
exposedByDefault: false
network: proxy
watch: true
```

**`endpoint`** does not point at `/var/run/docker.sock`. Mounting that socket,
even `:ro`, grants the full Docker API, which is root on the host: anyone who
reaches it can start a privileged container that bind-mounts `/`. The `:ro`
protects the socket *file*, not the API behind it. Traefik is the most
internet-exposed process here, so it gets `socket-proxy`, which permits
`/containers`, `/networks`, `/events`, `/version` and refuses every POST.

**`exposedByDefault: false`** makes routing opt-in via `traefik.enable=true`.
The default (`true`) means every container that lands on the proxy network is
one stray label away from being public.

**`network: proxy`** is the fallback for a container attached to several
networks. Per-container `traefik.docker.network` overrides it. Get this wrong
and you get a 502 against a perfectly healthy backend, because Traefik dialed
an address it cannot route to.

### `file`

```yaml
directory: /etc/traefik/dynamic
watch: true
```

Watched, applied in about a second. Only `.yml` / `.yaml` / `.toml` / `.json`
are read, which is why `.htpasswd` could sit in this directory without being
parsed — but it now lives in `secrets/` regardless, because credentials do not
belong in a directory Traefik scans.

A syntax error here does **not** take Traefik down. It logs
`error while reading configuration` and keeps the previous state, so the
observable symptom is "my change did nothing". Check the log.

## `certificatesResolvers`

```yaml
cloudflare:
  acme:
    email: "roneybd85@gmail.com"
    storage: /etc/traefik/certs/acme-cloudflare.json
    keyType: EC256
    dnsChallenge:
      provider: cloudflare
      resolvers: ["1.1.1.1:53", "1.0.0.1:53"]
      propagation:
        delayBeforeChecks: 0s
```

`email` is hardcoded because there is no variable expansion here. Changing it
means editing this file.

`storage` is one JSON file holding the ACME account key and every issued
certificate with its private key. Back it up (`make backup`), keep it `0600`.
Losing it is not fatal but re-issues everything, and Let's Encrypt rate limits
are per-week — 5 duplicate certificates per week per exact domain set. That
limit is also why `caServer` pointing at staging is commented in place: use it
while experimenting.

`keyType: EC256` — smaller, faster handshakes, universally supported now.

**`resolvers`** makes Traefik ask Cloudflare's own resolvers whether the
`_acme-challenge` TXT record is visible before telling Let's Encrypt to look.
Without it, Traefik uses the container's resolver, which may be a caching
resolver that answers from a stale negative cache — the classic "challenge
timed out" that fixes itself on the third attempt.

**`propagation.delayBeforeChecks: 0s`** replaces the deprecated
`delayBeforeCheck` (removed in favour of this in v3.2). The old value of `60s`
was a flat sleep on *every* issuance and renewal, on top of the propagation
check that already does this properly.

Also here: `letsencrypt`, HTTP-01, as a fallback for domains not on Cloudflare.
It cannot issue wildcards and needs `:80` reachable from the internet.

**Why DNS-01 is the default:** wildcards, issuance before DNS points at this
host, and it works with `:80` firewalled — which matters if you later move to a
Cloudflare Tunnel and have no inbound ports at all.

## `metrics`

```yaml
prometheus:
  entryPoint: metrics
  addEntryPointsLabels: true
  addRoutersLabels: true
  addServicesLabels: true
```

On the unpublished `metrics` entryPoint (`:9100`), so it is scrapeable from the
`proxy` network and nowhere else. `addRoutersLabels` multiplies series by the
number of routers; on a host with hundreds of routes, turn it off before it
becomes your largest metric.

---

## Reload matrix

| Change | Action |
|---|---|
| anything in `config/traefik.yml` | `make restart` |
| `config/dynamic/*.yml` | nothing — live in ~1s |
| `secrets/.htpasswd` | nothing — read per request |
| `secrets/cf_dns_api_token` | `make restart` — read once at start |
| a container's labels | nothing — the events stream picks it up |
| the `traefik:v3.6` tag | `make pull && make up` |

## Before every `make up`

```bash
make check     # YAML parse + boot Traefik and fail on any error-level log
```

There is no `traefik validate` subcommand. `make check` is the substitute: it
starts the real binary against the real files in a throwaway container, waits,
and greps for `"level":"error"`. It catches unknown keys, bad CIDRs, unparseable
durations and broken anchors — everything that would otherwise be discovered by
`:443` going down.
