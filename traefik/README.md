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
> `../Dockerfile` or `../apps/` depends on these files.

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
| [`STATIC-CONFIG.md`](STATIC-CONFIG.md) | every static property, and why |
| [`LABELS.md`](LABELS.md) | the labels an app repo needs |
| [`AUDIT.md`](AUDIT.md) | what changed from the previous config, what was broken, and what was verified |

The static/dynamic split is not stylistic. Traefik reads `traefik.yml` once at
process start and cannot reload it; the file provider watches `dynamic/` and
applies changes in about a second. If a change "did nothing", that is the first
thing to check.

## First run

```bash
make init                      # proxy network, certs/, secrets/, .env
$EDITOR .env                   # TRAEFIK_DOMAIN
make token                     # Cloudflare DNS API token (prompted, not echoed)
make htpasswd USER=admin       # dashboard login
make check                     # parse configs, boot Traefik, fail on any error
make up
make doctor
```

Two things in `config/traefik.yml` must be edited by hand, because Traefik does
**not** expand `${VAR}` in static config:

- `certificatesResolvers.*.acme.email`
- the `trustedIPs` list, if your networks are not RFC1918

## Day to day

```bash
make logs                      # follow
make logs-access               # access log only, one line per request
make certs                     # issued domains + expiry
make doctor                    # the checks that fail silently
make doctor https://lms.freshie.farm   # + live X-Forwarded-For spoof test
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

```cron
0 6 * * 1  cd /opt/traefik && make cf-ips || mail -s "traefik: cloudflare IPs changed" you@example.com
```

## Adding an application

Nothing is added here. The app declares itself:

```yaml
labels:
  - traefik.enable=true
  - traefik.docker.network=proxy
  - traefik.http.services.lms.loadbalancer.server.port=8080
  - traefik.http.routers.lms.rule=Host(`lms.freshie.farm`)
  - traefik.http.routers.lms.entrypoints=websecure
  - traefik.http.routers.lms.tls.certresolver=cloudflare
  - traefik.http.routers.lms.middlewares=chain-web@file
```

Full reference, including the parts that are easy to get wrong (`$${1}` in
labels, `@file` suffixes, worker containers, `passHostHeader`), is in
[`LABELS.md`](LABELS.md). Every template in [`../apps/`](../apps/) already
carries the first three lines.

## Design decisions

**No raw Docker socket.** Traefik talks to `socket-proxy`, which allows
`/containers`, `/networks`, `/events`, `/version` and refuses every POST.
`/var/run/docker.sock` mounted `:ro` is still unrestricted Docker API access —
the `:ro` protects the socket *file*, not the API — and that is root on the
host. Handing it to the most internet-exposed process on the box is the single
largest risk in a labels-driven setup.

**Host-mode port publishing.** `mode: host` rather than the default bridge
publishing, so the TCP peer address is the real one. Through `docker-proxy`
every connection is SNATed to the bridge gateway, which makes the `trustedIPs`
check meaningless — it would be comparing against the gateway, not against
Cloudflare.

**Read-only root filesystem.** Both containers. Traefik writes only to
`certs/` and a small `tmpfs`.

**Token in a file, not an environment variable.** `CF_DNS_API_TOKEN_FILE`.
Environment variables are visible in `docker inspect` and
`docker compose config` to anyone in the `docker` group. Use a scoped
*Zone / DNS / Edit* token, never the Global API Key, and do not also set
`CF_API_EMAIL` — that switches lego to the account-wide key.

**Access logs are not filtered to 4xx/5xx.** A `200` that should have been a
`403` is invisible if you only log errors, and successful requests are where
you read client IPs. Rotation is the Docker logging driver's job.

**DNS-01 by default.** It issues wildcards, works before DNS points here, and
works with `:80` firewalled. `letsencrypt` (HTTP-01) stays configured for
domains not on Cloudflare — it still works despite the `:80 → :443`
redirect, because Traefik installs a higher-priority router for
`/.well-known/acme-challenge/`.

## Cloudflare settings this assumes

Covered in detail in [`../docs/reverse-proxy.md`](../docs/reverse-proxy.md).
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
