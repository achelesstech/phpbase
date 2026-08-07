# Portainer CE — behind Traefik, single host

A container UI for this host. Replaces the official guide's
`docker run -p 9443:9443 …` with a compose file that publishes no ports and is
reachable only through Traefik.

```
you ──TLS──► Cloudflare ──► Traefik ──► chain-admin-restricted ──► portainer:9000
                                        (IP allowlist,             (docker.sock)
                                         basic auth,
                                         rate limit)
```

> Same temporary home as [`../traefik/`](../traefik/): it lives here so the
> proxy and what it fronts can be reviewed together, and moves to its own
> repository later. Nothing in `php-base` depends on it.

**Read [`AUDIT.md`](AUDIT.md)** for what was wrong with the `docker run`
install and why each change is here. Everything in it was verified against
portainer-ce 2.39.5 rather than read off documentation.

## Read this before installing it

**Portainer is root on this host.** Its job is creating and exec-ing into
containers, which is `POST` on the Docker API, so it needs a read-write
`docker.sock`. Unlike Traefik it *cannot* go behind the GET-only socket proxy —
that would make it a read-only dashboard. No capability dropping or read-only
filesystem changes this.

So the hardening here is entirely about **reachability and authentication**, and
the defaults reflect that: `chain-admin-restricted@file` allows **private ranges
only**. Out of the box you reach the UI over a VPN or an SSH tunnel:

```bash
ssh -L 8443:127.0.0.1:443 deploy@<vps>     # then https://portainer.example.com via /etc/hosts
```

Putting it on the public internet means adding your egress IP to
`ipallowlist-admin` in the Traefik config. That is a deliberate widening, not a
missing step.

## Install

Traefik must be up first — this uses its `proxy` network and its middlewares.

```bash
make init                 # .env, encryption key, admin password
$EDITOR .env              # PORTAINER_DOMAIN — bare hostname, no scheme
make check                # validates before anything starts
make up
make doctor
```

`PORTAINER_DOMAIN` is used twice: the Traefik router rule and Portainer's
`--trusted-origins`. It must be a **bare hostname** — `https://…`, a trailing
slash or a port each make Portainer exit at startup with
`invalid url for trusted origin`. `make check` catches that before you hit it.

Add a DNS record for the hostname. DNS-01 issues the certificate, so it does not
need to resolve to this host for TLS to work — but Traefik still routes on the
`Host` header, so it does need to resolve somewhere you control.

## Migrating the existing `docker run` install

```bash
make adopt      # prints this
```

The volume is called `portainer_data` in both, and this compose file pins that
exact name, so it is adopted rather than recreated. Users, environments and
settings survive:

```bash
docker stop portainer && docker rm portainer
make init && make up
```

Two things:

- `make password` will decline — an admin already exists, and Portainer logs
  `administrator user defined, skipping admin password related flags`. The file
  still has to exist, or startup is fatal.
- **Do not enable the encryption key on an existing store without backing it up
  first.** `make init` generates one. If you are adopting, run `make backup`
  *before* `make up`, or delete `secrets/encryption_key` and leave the store
  unencrypted for now.

## Day to day

```bash
make logs
make doctor            # the checks that fail silently
make version
make backup            # volume + encryption key, together
make pull && make check && make up
```

`make doctor` is the one to run after any change. It verifies no port has been
published, that `--trusted-origins` still matches the router rule, that the
router still carries the admin chain, and that the store's encryption state
matches what you think it is.

```cron
0 2 * * *  cd /opt/portainer && make backup && rclone move portainer-backup-*.tgz remote:backups/
```

## Backups — read this once

`make backup` stops the container, tars the volume **and** `secrets/`, and
restarts it. It stops the container on purpose: BoltDB is memory-mapped, and a
tar of a live database is a copy of an inconsistent one — which usually
restores, the worst property a backup can have.

**A volume backup alone is worthless once the store is encrypted.** Restoring it
without `secrets/encryption_key` gives you

```
fatal: The portainer database is encrypted, but no secret was loaded
```

and there is no recovery. That is why the two are tarred together — and why the
tarball must live somewhere other than this host, encrypted.

## What each flag does

| Flag | Why |
|---|---|
| `--http-enabled` | serve plain `:9000`; TLS terminates once, at Traefik |
| `--admin-password-file` | creates the admin at boot, avoiding the five-minute setup window that closes while DNS is still propagating |
| `--trusted-origins` | CSRF. Without it the UI loads and every login 403s, which reads as a wrong password |
| `--csp` | `object-src 'none'; frame-ancestors 'none'` from Portainer itself |
| `--log-mode=JSON` | parseable, and no ANSI colour codes in the log |

Full reasoning in [`AUDIT.md`](AUDIT.md).

## No healthcheck, deliberately

The image has no shell, `curl` or `wget` — `docker exec portainer sh` returns
`executable file not found`. A `HEALTHCHECK` copied from elsewhere cannot
execute, so the container reports unhealthy forever, and anything acting on
health turns that into a restart loop.

If you want one, put it on the Traefik side:

```yaml
- traefik.http.services.portainer.loadbalancer.healthcheck.path=/
- traefik.http.services.portainer.loadbalancer.healthcheck.interval=30s
```

For the same reason `make doctor` makes its requests from a throwaway `curl`
container joined to Portainer's network namespace, which is also the only way to
reach `:9000` now that nothing is published.

## Use it to read, not to deploy

Stacks created through the Portainer UI live in `portainer_data`, not in git.
That fights the model in [`../apps/`](../apps/), where the repo is the source of
truth and migrations are `--profile ops` jobs. The next deploy from the app repo
will not know about a UI-defined stack.

Logs, stats, inspecting a container, a quick exec when something is on fire —
genuinely useful, and worth having. Defining infrastructure — keep that in the
repo.
