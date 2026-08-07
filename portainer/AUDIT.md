# Audit — the official `docker run` install

The Portainer install on the current host follows the official CE quick-start:

```bash
docker volume create portainer_data
docker run -d -p 8000:8000 -p 9443:9443 --name portainer --restart=always \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  portainer/portainer-ce:lts
```

This reviews that command. It is not a bad quick-start — it is a quick-start,
written for someone with no reverse proxy who needs a UI in sixty seconds. Every
finding below is a consequence of keeping it once a proxy exists.

Behaviours were verified against **portainer-ce 2.39.5** locally, not read off
documentation. Where a claim came from a test, the test's output is quoted.

---

## 1. `-p 9443:9443` is a second, unguarded front door

The finding that matters, and the reason for everything else here.

Portainer serves its own HTTPS on 9443 with a self-signed certificate.
Published, it is reachable from the internet directly, which means it bypasses:

- the IP allowlist
- basic auth
- the rate limit (so its login form can be brute-forced at line speed)
- HSTS and the real certificate
- the access log — nothing about those requests appears in Traefik's log at all

For an ordinary app that is untidy. For Portainer it is different in kind: the
container holds a read-write Docker socket, so anyone who gets through that
login has root on the host. Both doors lead to the same place, and only one of
them is guarded.

And per `../traefik/VPS-SETUP.md`, **`ufw status` will not show it as open** —
Docker inserts its iptables rules ahead of ufw's. The port can be exposed on a
box whose firewall reports `deny incoming`.

**Now:** no `ports:` at all. Traefik reaches `:9000` over the `proxy` network
and the router sits behind `chain-admin-restricted@file`. `make check` fails the
build if a published port ever comes back.

## 2. `-p 8000:8000` is an open port for an unused feature

That is the Edge agent tunnel, for managing remote hosts. On a single-host
install nothing connects to it. Portainer still binds it inside the container —
unpublished, that is inert.

**Now:** not published. If you later add a second host, open it deliberately and
behind the allowlist.

## 3. No `--trusted-origins`, which breaks the UI behind a proxy

Portainer enforces CSRF by checking the request `Origin`. On `localhost:9443`
that is automatic. Behind Traefik on a custom hostname it is not: the UI loads
fine, and then login fails and every API call 403s. It reads as a wrong
password, which is why people conclude "Portainer doesn't work behind a proxy".

The flag takes a **bare hostname**. Verified — all three of these are fatal at
startup, container exits after a few seconds:

```
--trusted-origins=https://portainer.example.com     fatal: invalid url for trusted origin
--trusted-origins=https://portainer.example.com/    fatal: invalid url for trusted origin
--trusted-origins=https://portainer.example.com:443 fatal: invalid url for trusted origin
--trusted-origins=portainer.example.com             starts
```

**Now:** set from `PORTAINER_DOMAIN`, the same variable as the router rule, so
the two cannot drift. `make check` rejects a value with a scheme, slash or port
before you hit the fatal; `make doctor` cross-checks the running flag against
the running router rule.

## 4. Nothing serves plain HTTP, so Traefik has to talk TLS to a self-signed cert

Default startup (verified) binds **both**:

```
starting HTTPS server  bind_address=:9443
starting HTTP server   bind_address=:9000
```

so 9000 is available. Routing to 9443 instead would mean giving Traefik a
`serversTransport` with `insecureSkipVerify`, terminating TLS twice for a hop
that never leaves the host.

**Now:** `--http-enabled`, router points at `:9000`, TLS terminates once at
Traefik. 9443 keeps listening inside the container and is simply unused.

## 5. The admin bootstrap has a five-minute fuse

With no admin password supplied, Portainer waits for you to create the first
user through the UI and closes that window shortly after startup. Miss it — the
usual cause being that DNS or the certificate is not ready yet — and you must
restart the container to reopen it. On a fresh box, where Portainer usually
comes up before its hostname resolves, that is the normal case rather than the
exception.

**Now:** `--admin-password-file`, so the admin exists before the first request.
Two behaviours verified, both of which matter operationally:

- With the file present and an admin already created, Portainer logs
  `administrator user defined, skipping admin password related flags` and
  starts normally. Rotating the password in the UI does not conflict with it.
- With the flag set and the file **deleted**, Portainer exits:
  `fatal: could not get the contents of the file`. So the file has to stay —
  it is not a one-shot you can clean up afterwards.

The file is read verbatim, so a trailing newline becomes part of the password.
`make init` writes it with `printf`, and `make check` rejects a file that ends
in one — otherwise you get "invalid credentials" on a password you are certain
is correct.

## 6. The data store is not encrypted at rest

Default startup, verified:

```
info | encryption key file not present
info | proceeding without encryption key
```

`portainer_data` holds the JWT signing secret, user password hashes, and any
container-registry credentials you add. Anyone who can read the volume — a host
backup, a stolen disk image, another container mounting it — gets all of it.

Portainer reads a key from `/run/secrets/portainer` and encrypts the store.
Verified working: with the secret mounted, the "proceeding without" lines are
absent and authentication still succeeds.

**This is a real footgun and it is on by default here.** Verified: booting an
encrypted store *without* the key is

```
fatal: The portainer database is encrypted, but no secret was loaded
```

and there is no recovery path. That is why `make backup` refuses to be just a
volume dump — it tars the key alongside it, and `make doctor` warns if no local
backup exists.

## 7. Everything else

| | Was | Now |
|---|---|---|
| Tag | `:lts` — moves under you | `:2.39.5`, Renovate bumps it |
| Restart | `--restart=always` — restarts even after a deliberate `docker stop` | `unless-stopped` |
| `no-new-privileges` | not set | set |
| Log rotation | daemon default (unbounded on most hosts) | `json-file`, 20m × 5 |
| Log format | pretty, ANSI colour codes in the log file | `--log-mode=JSON` |
| CSP | off | `--csp` — verified: `object-src 'none'; frame-ancestors 'none'` |
| Config | recoverable only from `docker inspect` | a file in git |

---

## Why this cannot be hardened the way Traefik was

The central move in the Traefik rewrite was taking away the Docker socket.
Traefik only needs to *read* containers, so a GET-only proxy covers it
completely with nothing lost.

**That does not transfer.** Creating, starting, stopping and exec-ing into
containers is Portainer's entire purpose, and all of it is `POST` on the Docker
API — the half the socket proxy exists to refuse. Put Portainer behind it with
`POST: 0` and you have a read-only dashboard; with `POST: 1` you have the raw
socket with extra steps.

So Portainer is root-equivalent on this host, by design, permanently. No
capability dropping, read-only filesystem or user namespace changes that. The
hardening available is entirely about **who can reach it** and **who can
authenticate**, which is why the router carries an IP allowlist and basic auth
in front of Portainer's own login rather than relying on that login alone.

Worth stating plainly: `chain-admin-restricted@file` as shipped allows **private
ranges only**. Out of the box the UI is reachable through a VPN or
`ssh -L 8443:127.0.0.1:443 …`, and not from a browser on the internet. That is
the correct default for this particular service. Adding your egress IP is a
deliberate decision to widen it, not a step you have skipped.

## A note on how it fits the rest of the stack

You now have per-app compose files in `apps/`, with `--profile ops` jobs for
migrations and the repository as the source of truth. Portainer's "deploy a
stack from the UI" workflow directly contradicts that: stacks created there live
in `portainer_data`, not in git, and the next `docker compose up -d` from the
app repo does not know about them.

It is genuinely useful as a **read** surface — logs, stats, container
inspection, a quick exec when something is on fire. I would keep it for that and
define stacks in the repo.

---

## Verified

Against `portainer/portainer-ce:2.39.5`:

- Default startup binds `:9000` HTTP, `:9443` HTTPS and `:8000` tunnel.
- `--trusted-origins` accepts a bare hostname; scheme, trailing slash and port
  are each a startup fatal.
- `--admin-password-file` with a plaintext file creates the admin
  (`created admin user with the given password`) and `POST /api/auth` then
  returns **200**.
- A second boot with an existing admin skips the flag and starts cleanly; with
  the file removed it is fatal.
- The encryption secret at `/run/secrets/portainer` is picked up, auth still
  returns 200, and booting the encrypted store without it is fatal.
- `--csp` emits `Content-Security-Policy: … object-src 'none';
  frame-ancestors 'none'` plus `X-Content-Type-Options: nosniff`.
- **The image has no shell**: `docker exec portainer sh` is
  `exec: "sh": executable file not found in $PATH`. No `curl`, no `wget`
  either. This is why there is no `HEALTHCHECK` — a copied-in one cannot run,
  so the container would report unhealthy forever — and why the doctor makes
  its requests from a throwaway curl container sharing the network namespace.

## Not tested here

The Traefik route end to end. It needs a live certificate and DNS, so the
router rule, the allowlist and the CSRF origin are only exercisable on the host.
`make check` verifies the middlewares this router references actually exist in
the Traefik config, and `make doctor` cross-checks the running flags against the
running labels, but neither can prove a browser reaches the UI. Run
`make doctor` on the VPS after `make up`.
