# Audit of the previous configuration

Review of `/opt/treafik` as it stood, and what changed here. Ordered by
consequence, not by file.

The pattern worth naming up front: **almost nothing here was a startup error.**
Every finding in the first two sections describes a configuration that boots
cleanly, logs nothing, serves traffic, and does the wrong thing. That is
Traefik's characteristic failure mode, and it is why `make check` and
`make doctor` exist.

---

## Silently broken

### 1. Per-IP rate limiting was not per-IP

```yaml
sourceCriterion:
  ipStrategy:
    depth: 2
```

`depth` counts from the right of `X-Forwarded-For`. In this chain the header
arriving at Traefik has exactly **one** entry:

```
client → Cloudflare → Traefik      XFF: "<client>"
client → Traefik (direct)          XFF: "<client>"   (Traefik sets it)
```

When `depth` exceeds the number of entries, Traefik yields an empty source. All
three rate limiters therefore collapsed into one global bucket: one busy user
exhausted the limit for everybody, and no individual attacker was ever slowed.
It was on all three limiters, so `rate-limit-strict` on the dashboard was
affected too.

Changed to `depth: 1`, which is correct in both topologies above **and**
spoof-resistant: a client who forges `X-Forwarded-For: 1.2.3.4` gets the real
address appended by Cloudflare, so the rightmost entry is still real.
`make doctor` asserts it.

### 2. Cloudflare's IPv6 ranges were missing from `trustedIPs`

Both entryPoints listed the 15 IPv4 ranges and none of the 7 IPv6 ranges. If
the origin has an `AAAA` record — and it will, once anything on the host is
dual-stacked — Cloudflare connects over IPv6, is not trusted, and Traefik
**overwrites** `X-Forwarded-For` with Cloudflare's own address.

Every backend then sees Cloudflare as the client. Moodle login throttling,
Drupal flood control, Laravel rate limiting and every access log break at once,
with no error anywhere. It is the same end state as having no forwarded-header
config at all, reached from the opposite direction.

Interestingly `docs/reverse-proxy.md` in this repo already listed the v6 ranges;
the live config had drifted from the documentation.

### 3. The CORS origin allowlist matched nothing

```yaml
accessControlAllowOriginList:
  - "https://*.example.com"
```

`accessControlAllowOriginList` is an **exact string** comparison. No `Origin`
header is ever literally `https://*.example.com`, so every cross-origin
request was rejected and the middleware added latency and nothing else.
Wildcards require the regex variant:

```yaml
accessControlAllowOriginListRegex:
  - "^https://([a-z0-9-]+\\.)*example\\.com$"
```

Also added `accessControlAllowCredentials: true`, without which a browser
discards the response for any authenticated cross-origin request.

### 4. `chain-admin` returned 403 to everyone

```yaml
chain-admin:
  chain:
    middlewares: [secure-headers, basic-auth, rate-limit-strict, ip-allowlist-private]
```

`ipAllowList` with no `ipStrategy` checks the **TCP peer address**. Behind
Cloudflare that is always a Cloudflare address, never `10/8`. Any router using
this chain was unreachable, including from your own browser.

The two uses of an IP allowlist need opposite strategies, so they are now two
named middlewares:

| Intent | Checks | Config |
|---|---|---|
| "only Cloudflare may connect" | TCP peer | `ipallowlist-cloudflare-edge`, no `ipStrategy` |
| "only my office may browse" | end user | `ipallowlist-admin`, `ipStrategy.depth: 1` |

### 5. Large uploads died at 60 seconds

No `respondingTimeouts` were set, so `websecure` used Traefik's 60s default
`readTimeout` — which bounds reading the entire request *including the body*.

A 200 MB Moodle course backup on a 10 Mbit link takes about three minutes. It
failed as a dead connection with nothing in the PHP log, because PHP never ran:
the request never finished arriving. This is a strong candidate for part of
"Moodle would not work on nginx" — `php-base` sets `client_max_body_size 512m`
and `PHP_UPLOAD_MAX_FILESIZE=512M`, and the proxy in front silently capped it by
time rather than by size.

Now `readTimeout: 600s`, `writeTimeout: 0` (so long downloads and streamed
`pluginfile.php` responses are not cut off), plus `lifeCycle` grace timeouts so
a restart mid-upload drains instead of 502-ing.

### 6. `ACME_EMAIL` did nothing

`compose.yml` passed `ACME_EMAIL` into the container. Traefik does **not**
expand `${VAR}` in static config, and nothing else reads that variable — the
email actually used was the literal string in `traefik.yml`. Harmless here
because both happened to be the same address, but it is the kind of assumption
that produces a config where you believe `.env` controls something it does not.

`.env.example` now says so explicitly, and `ACME_EMAIL` is gone.

---

## Defaults that break applications

### 7. A shared Content-Security-Policy in the default chain

`chain-default` → `secure-headers` → `default-src 'self'`.

CSP is per-application, never per-proxy. Attached to Moodle it breaks inline
handlers, `blob:` workers and MathJax; on WordPress the block editor; on Drupal
CKEditor. The failure is blank panels and dead buttons with **nothing in the
server log** — the errors exist only in the browser console, which makes it one
of the most expensive possible defaults.

Moved out of `security-headers` into an opt-in `csp-strict@file`, with
`worker-src 'self' blob:` added.

### 8. `X-Robots-Tag: none` on every public site

`secure-headers.customResponseHeaders` sent
`none,noarchive,nosnippet,notranslate,noimageindex`, and `secure-headers` was in
`chain-default`. Anything using the default chain was de-indexed from every
search engine.

Split into an opt-in `noindex@file` for staging and admin surfaces.

### 9. `buffer-uploads` would have 413'd Moodle

Not attached to any chain, so it was inert — but it was named for uploads and
capped them at 100 MB. `buffering` also reads the entire body before the backend
sees a byte, which adds full-upload latency and breaks streaming responses and
websockets.

Renamed `buffer-small-requests`, dropped to 10 MB, and documented as
*do not attach this to a PHP application*.

### 10. `browserXssFilter: true`

Sends `X-XSS-Protection: 1; mode=block`. The legacy XSS auditor is deprecated,
removed from Chrome, and has itself been the source of information-disclosure
bugs. Current guidance is to send `0`. Replaced with an explicit
`X-XSS-Protection: "0"`.

### 11. `stsPreload: true`

A request to be compiled into every browser's HSTS list, covering the apex and
every subdomain — including ones that do not exist yet, and any internal tool
you later put on plain HTTP. Effectively irreversible for months, and it does
nothing unless you actually submit the domain at hstspreload.org.

Now `false`, with `stsSeconds` at one year rather than two, and a comment
explaining when to turn it on.

---

## Security posture

### 12. The raw Docker socket

```yaml
volumes:
  - /var/run/docker.sock:/var/run/docker.sock:ro
```

`:ro` protects the socket *file*, not the API behind it. Full Docker API access
is equivalent to root on the host: start a privileged container, bind-mount `/`.
This was held by the single most internet-exposed process on the machine, and a
Traefik CVE or a malicious plugin would have inherited it.

Replaced with `tecnativa/docker-socket-proxy`, on an `internal: true` network
(no route off the host), allowing `CONTAINERS`, `NETWORKS`, `EVENTS`, `VERSION`,
`PING` and explicitly refusing `POST` — which is the setting that actually
matters; without `POST: 0` the proxy is barely better than the socket.

### 13. The Cloudflare token was an environment variable

`CF_DNS_API_TOKEN` in `environment:` is visible in `docker inspect`, in
`docker compose config`, and in the environment of anyone in the `docker` group.
Now a file secret via `CF_DNS_API_TOKEN_FILE`, mode `0600`, created by
`make token` without echoing.

`CF_API_EMAIL` was also set alongside the token. That variable selects lego's
**Global API Key** path — account-wide, unscopable, and unrevokable without
breaking everything else that uses it. Removed, with a comment saying not to
re-add it.

### 14. The dashboard had auth but no IP restriction

`dashboard-chain` was `secure-headers + basic-auth + rate-limit-strict`, and the
rate limit was the broken one from finding 1. Basic auth over TLS is a real
control, but the dashboard enumerates every route, service and backend address
on the host.

Now `ipallowlist-admin + ratelimit-strict + basic-auth + security-headers +
noindex`, on `tls.options=modern@file`, `priority=1000`.

### 15. `.htpasswd` inside the watched config directory

`usersFile: /etc/traefik/dynamic/.htpasswd`. It happened to be ignored — the
file provider only reads `.yml`/`.yaml`/`.toml`/`.json` — but credentials do not
belong in a directory Traefik scans, and one day that directory gets mounted
somewhere or copied. Moved to `secrets/`, mounted `:ro`, `0600`.

### 16. Container hardening

`no-new-privileges`, `cap_drop: ALL` and `cap_add: NET_BIND_SERVICE` were
already right. Added `read_only: true` with a small `tmpfs` (Traefik writes only
to the ACME store) and `ulimits.nofile: 65535` — Traefik holds two descriptors
per connection, the default 1024 is reached at a few hundred concurrent users,
and the symptom is `accept: too many open files` with requests hanging rather
than failing.

---

## Operability

### 17. Logs went to files inside the container

```yaml
log:
  filePath: "/var/log/traefik/traefik.log"
accessLog:
  filePath: "/var/log/traefik/access.log"
```

Invisible to `docker logs`. It also made the `logging:` json-file driver in
`compose.yml` almost a no-op — it was rotating an empty stream while the real
logs were rotated by Traefik's own `maxSize`/`maxBackups`, in a bind mount, on
a schedule nothing else knew about. Two rotation mechanisms, neither obviously
in charge.

Both now go to stdout/stderr, and the Docker logging driver handles rotation.

### 18. Access logs were filtered to `400-599`

```yaml
filters:
  statusCodes: ["400-599"]
```

You cannot verify client IPs, prove what an allowlist did, or notice a `200`
that should have been a `403`, if successful requests are not logged. Removed
(kept commented, with the trade-off written down). `Cookie` added to the
drop list alongside `Authorization`.

### 19. `delayBeforeCheck: 60s`

A flat 60-second sleep on every issuance **and every renewal**, on top of the
propagation check that `resolvers` already performs properly. Deprecated in
v3.2 in favour of `propagation.delayBeforeChecks`. Now `0s`.

### 20. Two copies of the trusted-IP list

Both entryPoints carried the same 19 lines. They will drift, and the copy that
drifts is the one you are not looking at — which for `web` is easy to miss,
since it only issues redirects. Now a YAML anchor: one list, aliased.

### 21. `routers.yml` was comments only

Fine, but the file provider logs "no configuration found" for a file with no
usable content. Now `http: {}` plus three worked examples (a LAN backend, a
higher-priority path router reusing a Docker-defined service, a domain
redirect), because the reason to open that file is always "how do I add X".

---

## Already right — kept

- `exposedByDefault: false`. Opt-in routing.
- `api.insecure: false`. No unauthenticated `:8080`.
- `ping` and `metrics` on their own unpublished entryPoints.
- `mode: host` port publishing. Bridge publishing SNATs through
  `docker-proxy`, which makes the `trustedIPs` check meaningless because every
  peer becomes the bridge gateway. This was the right call and it is easy to get
  wrong.
- HTTP/3 with UDP/443 published, `advertisedPort: 443`.
- `sniStrict: true` and the TLS 1.2 cipher list — AEAD only, forward secrecy
  only, no CBC. Kept verbatim; added `maxVersion`, `alpnProtocols`, and a
  `compat` option as a per-router escape hatch.
- Pinning the minor (`traefik:v3.6`) rather than `:v3`.
- Both entryPoints redirecting `:80 → :443` permanently.
- `compress` with zstd/br/gzip and an excluded-types list (added
  `text/event-stream`: buffering an SSE stream to compress it means the client
  receives nothing until it ends).
- `circuit-breaker` and `retry` definitions — left unattached, with the POST
  replay caveat now written down.

---

## Verified

Against `traefik:v3.6.25` on this machine, with a throwaway compose project and
a `traefik/whoami` container carrying real labels:

- `make check` passes: YAML parses, both entryPoints share one `trustedIPs`
  list (28 ranges), the static and dynamic configs load, and
  `traefik healthcheck --ping` answers — so the compose healthcheck would pass.
- `make check` **fails correctly** on three deliberate breaks: an invalid CIDR
  in `trustedIPs` (Traefik exits; reported as
  `invalid CIDR address: 131.0.72.0/99`), an unknown middleware field
  (`field not found, node: comprezz`), and an entryPoint with
  `forwardedHeaders` removed — the spoofing hole, caught before Traefik even
  starts.
- `make cf-ips` reports the committed ranges as an exact match for the live
  list (15 IPv4 + 7 IPv6).
- All **26** middlewares from `dynamic/` load and report `enabled` — including
  the CORS regex, both `ipAllowList` variants and all four rate limiters.
- The Docker provider works through the socket proxy: haproxy logs `200` for
  `/version` and every `/containers/{id}/json`, and the whoami container's
  routers were discovered and built. So the allowlist (`CONTAINERS`,
  `NETWORKS`, `EVENTS`, `VERSION`, `PING`, `POST: 0`) is sufficient.
- A router with no `tls.options` resolves to `default`; one with
  `tls.options=modern@file` resolves to `modern@file`. Both `enabled`.
- `docker compose config` resolves cleanly, and **fails loudly** with
  `required variable TRAEFIK_DOMAIN is missing a value` when `.env` is
  incomplete — rather than publishing a dashboard on an empty hostname.

### Two bugs found in this rewrite while verifying it

1. **`options: default@file` on the `websecure` entryPoint.** Symmetrical with
   `modern@file`, and wrong: `default` is registered without a provider suffix.
   Traefik logged `unknown TLS options: default@file` and **failed to build
   every router on the entryPoint** — total outage, healthy container, no
   obvious cause. Removed; `default` is applied automatically anyway.
2. **`read_only: true` on the socket proxy.** The image is haproxy and its
   entrypoint renders `haproxy.cfg` from the environment at start, so it
   crash-looped on `can't create ... haproxy.cfg: Read-only file system`.
   Tmpfs-ing that directory instead masks the `haproxy.cfg.template` the image
   ships and fails one line later. Dropped `read_only` there (kept on Traefik)
   with the reason recorded in the file.

Both would have presented as "the proxy is up but nothing works".

## Not tested here

Bringing the real stack up end to end: it binds `:80`/`:443` and needs a live
Cloudflare token and DNS. The ACME path in particular — DNS-01 issuance, the
propagation check, `secrets/cf_dns_api_token` being read correctly — is only
exercisable on the host. Run `make check` then `make up`, and use the staging
`caServer` (commented in place in `config/traefik.yml`) for the first attempt:
the production endpoint allows 5 duplicate certificates per week and locks you
out of issuance for days once you hit it.

## Not addressed here

**Cloudflare Tunnel.** With a tunnel there are no inbound ports, the origin IP
cannot be found, and `ipallowlist-cloudflare-edge` becomes redundant. It is
strictly better than an IP allowlist and worth doing on the rebuild.

**Authenticated Origin Pulls** (mTLS from the edge). An IP allowlist proves a
request came through *Cloudflare*; Cloudflare's ranges are shared by every
Cloudflare customer, so it does not prove the request came through *your* zone.
mTLS does. The config is sketched in `config/dynamic/tls.yml` — enable it in the
Cloudflare dashboard first, or you lock yourself out.

**Host firewall.** Docker's iptables rules bypass most naive UFW setups; verify
with `iptables -S DOCKER-USER`, not `ufw status`.

**A staging ACME endpoint for the rebuild.** `caServer` is commented in place.
Use it while you are iterating, or you will hit the 5-duplicate-certificates-
per-week limit and be locked out of issuance for days.
