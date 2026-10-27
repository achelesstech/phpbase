# Traefik — the edge for this host

Every application built on `php-base` is a backend: plain HTTP on `:8080`, no
published ports, no TLS. This is the one component that faces the internet.

```
client ──TLS──► Cloudflare ──TLS──► Traefik ──plain HTTP──► nginx ──► php-fpm
                (edge)              :443                       :8080
                                    │
                        docker labels │ file provider
                                    ▼
                        app containers on the `proxy` network
```

> **This directory is a temporary home.** It lives here so the proxy and the
> images it fronts can be reviewed together. It will move to its own repository;
> `php-base` and the app repos should reference it, not vendor it. Nothing in
> `../../Dockerfile` or the app templates in `../` depends on these files.

## Contents

| File | Reloads |
|---|---|
| `compose.yml` | `make restart` |
| `config/traefik.yml` — static: entryPoints, providers, ACME, logging | **restart required** |
| `config/dynamic/middlewares.yml` | live |
| `config/dynamic/routers.yml` — non-Docker backends | live |
| `config/dynamic/tls.yml` | live |
| `scripts/check-config.sh` — `make check` | — |
| `scripts/traefik-doctor.sh` — `make doctor` | — |
| `scripts/cf-ips.sh` — `make cf-ips` | — |
| `scripts/acme-certs.sh` — `make certs` | — |
| [`docs/traefik/vps-setup.md`](../../docs/traefik/vps-setup.md) | bare VPS to serving traffic, in order |
| [`docs/traefik/static-config.md`](../../docs/traefik/static-config.md) | every static property, and why |
| [`docs/traefik/labels.md`](../../docs/traefik/labels.md) | the labels an app repo needs |

The static/dynamic split is not stylistic. Traefik reads `traefik.yml` once at
process start and cannot reload it; the file provider watches `dynamic/` and
applies changes in about a second. If a change "did nothing", that is the first
thing to check.

## First run

On a **fresh VPS**, start at
[`vps-setup.md`](../../docs/traefik/vps-setup.md) — it covers the host
itself (Docker install, the ufw/iptables trap, log rotation, the staging-ACME
step) in the order that avoids locking yourself out or burning a rate limit. On
a host that is already set up:

```bash
make init                      # proxy network, certs/, secrets/, .env (DOCKER_GID filled in)
$EDITOR .env                   # TRAEFIK_DOMAIN
make token                     # Cloudflare DNS API token (prompted, not echoed)
make htpasswd USER=admin       # dashboard login
make check                     # parse configs, boot Traefik, fail on any error
make up
make doctor
```

### Placeholders to replace

Everything here ships with `example.com` and a placeholder email. `make doctor`
flags the ones still unset, but the first three matter before `make up`:

| Where | What | If left alone |
|---|---|---|
| `config/traefik.yml` | `certificatesResolvers.*.acme.email` (**twice**) | Let's Encrypt may reject the account, and has no contact for it |
| `.env` | `TRAEFIK_DOMAIN` | compose refuses to start — this one fails loudly |
| `.env` | `DOCKER_GID` — `make init` fills it from `stat -c %g /var/run/docker.sock` | compose refuses to start — loud too |
| `config/dynamic/middlewares.yml` | `cors.accessControlAllowOriginListRegex` | fails closed: every cross-origin request on `chain-api` is rejected, silently |
| `config/dynamic/middlewares.yml` | `ipallowlist-admin.sourceRange` | private ranges only — dashboard reachable via VPN/SSH tunnel, not a browser |
| `config/traefik.yml` | `trustedIPs`, if your networks are not RFC1918 | forwarded headers from your own proxies get overwritten |

The email and the trusted-IP list live in `config/traefik.yml` and **cannot**
move to `.env`: Traefik does not expand `${VAR}` in static config. The previous
setup passed `ACME_EMAIL` in through compose, where nothing read it.

## Day to day

```bash
make logs                      # follow
make logs-access               # access log only, one line per request
make certs                     # issued domains + expiry; exits 1 if any expire within 21 days
make doctor                    # the checks that fail silently
make doctor https://lms.example.com   # + live X-Forwarded-For spoof test
make cf-ips                    # committed Cloudflare ranges vs the live list
make backup                    # tar certs/ + secrets/  (private keys — encrypt it)
```

`make doctor` is the one worth running after any change. Traefik's
characteristic failure is a config that starts cleanly, logs nothing, and
quietly does the wrong thing — a trusted-IP list missing a range, a rate limit
whose source resolves to empty, an allowlist checking the proxy instead of the
client. Each check maps to one of those.

`make cf-ips` belongs in cron. Cloudflare adds ranges; when it does and this
config has not been updated, the new edge IPs become untrusted, Traefik
overwrites `X-Forwarded-For` with Cloudflare's own address, and every backend
starts treating the entire internet as one client. Nothing logs an error.

`make certs` belongs there too. Let's Encrypt stopped emailing expiry warnings
in 2025, and a renewal that keeps failing is otherwise silent until the
certificate expires. Traefik renews 30 days ahead, so `make certs` fails once a
certificate is inside 21 days: renewal has been failing for over a week. It
also fails when it cannot read a store, and Traefik writes `certs/acme-*.json`
as root with mode 0600, so run it from root's crontab (`sudo crontab -e`).

```cron
0 6 * * 1  cd /opt/traefik && make cf-ips || mail -s "traefik: cloudflare IPs changed" you@example.com
0 7 * * *  cd /opt/traefik && make certs  || mail -s "traefik: certificate expiring" you@example.com
```

## Adding an application

Nothing is added here. The app declares itself:

```yaml
labels:
  - traefik.enable=true
  - traefik.docker.network=proxy
  - traefik.http.services.lms.loadbalancer.server.port=8080
  - traefik.http.routers.lms.rule=Host(`lms.example.com`)
  - traefik.http.routers.lms.entrypoints=websecure
  - traefik.http.routers.lms.tls.certresolver=cloudflare
  - traefik.http.routers.lms.middlewares=chain-web@file
```

**`certresolver` follows the domain's DNS.** DNS on Cloudflare: `cloudflare`.
DNS anywhere else (Namecheap, GoDaddy, a local registrar): `letsencrypt`. The
default resolver can only issue for Cloudflare zones, so a site elsewhere
**must** set `letsencrypt` or its certificate never issues.

Full reference, including the parts that are easy to get wrong (`$${1}` in
labels, `@file` suffixes, worker containers, `passHostHeader`), is in
[`labels.md`](../../docs/traefik/labels.md). Every app template in
[`examples/`](../) already carries the first three lines.

## Design decisions

**No raw Docker socket.** Traefik talks to `socket-proxy`
([wollomatic/socket-proxy](https://github.com/wollomatic/socket-proxy)), which
answers only Traefik and only the GETs its Docker provider makes — version,
ping, the container list and inspect, events, networks — and refuses
everything else, every POST included. `/var/run/docker.sock` mounted `:ro` is
still unrestricted Docker API access — the `:ro` protects the socket *file*,
not the API — and that is root on the host. Handing it to the most
internet-exposed process on the box is the single largest risk in a
labels-driven setup.

The proxy runs as `nobody` and reads the socket through the group that owns
it, which differs between hosts. That is `DOCKER_GID` in `.env`: required,
compose refuses to start without it, and `make init` fills it in from
`stat -c %g /var/run/docker.sock`.

**Host-mode port publishing.** `mode: host` rather than the default bridge
publishing, so the TCP peer address is the real one. Through `docker-proxy`
every connection is SNATed to the bridge gateway, which makes the `trustedIPs`
check meaningless — it would be comparing against the gateway, not against
Cloudflare.

**Read-only root filesystem on both containers.** Traefik writes only to
`certs/` and a small `tmpfs`; the socket proxy is a single static binary and
writes nothing. Both drop every capability (Traefik keeps only
`NET_BIND_SERVICE`) and set `no-new-privileges`, and the socket proxy is on a
network with no route off the host.

**Traefik pinned by tag and digest.** `traefik:v3.6.25@sha256:…` in
`compose.yml`. `make check` boots exactly that image against `config/`, so
an upgrade is: change both tag and digest, read the
[migration notes](https://doc.traefik.io/traefik/migrate/v3/), `make check`,
then `make up`.

**Token in a file, not an environment variable.** `CF_DNS_API_TOKEN_FILE`.
Environment variables are visible in `docker inspect` and
`docker compose config` to anyone in the `docker` group. Use a scoped
*Zone / DNS / Edit* token, never the Global API Key, and do not also set
`CF_API_EMAIL` — that switches lego to the account-wide key.

**Access logs are not filtered to 4xx/5xx.** A `200` that should have been a
`403` is invisible if you only log errors, and successful requests are where
you read client IPs. Rotation is the Docker logging driver's job.

**DNS-01 by default, HTTP-01 for everything not on Cloudflare.** `cloudflare`
(DNS-01) issues wildcards, works before DNS points here, and works with `:80`
firewalled, but only for Cloudflare zones. `letsencrypt` (HTTP-01) is for every
domain whose DNS is hosted anywhere else. It still works despite the
`:80 → :443` redirect, because Traefik installs a higher-priority router for
`/.well-known/acme-challenge/`.

## Cloudflare settings this assumes

Covered in detail in [`../../docs/reverse-proxy.md`](../../docs/reverse-proxy.md).
The short version:

| Setting | Value | If wrong |
|---|---|---|
| SSL/TLS mode | **Full (strict)** | Flexible = infinite redirect loop that looks like an app bug |
| Always Use HTTPS | on | harmless duplication of the `:80` redirect |
| Max upload | 100 MB on Free/Pro | Moodle backups 413 at the edge; the app never sees it |
| Request timeout | 100 s, error 524 | run upgrades as `--profile ops` CLI jobs, never in a browser |
| Cache Everything | off, or bypass session cookies | one user's dashboard served to another |

## Hardening beyond this

In rough order of value:

1. **Cloudflare Tunnel.** No inbound ports at all; the origin IP cannot be
   found or reached. Makes `ipallowlist-cloudflare-edge` redundant.
2. **Authenticated Origin Pulls** (mTLS, see `config/dynamic/tls.yml`). An IP
   allowlist proves a request came through *Cloudflare*; mTLS proves it came
   through *your* Cloudflare zone. Cloudflare's ranges are shared by every
   customer.
3. **Host firewall**: `:80`/`:443` open only to Cloudflare, everything else
   closed. Docker's iptables rules bypass most naive UFW configs — verify with
   `iptables -S DOCKER-USER`, not with `ufw status`.
4. **Attach `ipallowlist-admin`** to every admin path, not only the dashboard.
   Edit its `sourceRange` first: as shipped it allows private ranges only,
   which means SSH tunnel or VPN.
