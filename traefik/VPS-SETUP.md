# Fresh VPS → Traefik serving traffic

Bare Debian/Ubuntu VPS to a working edge, in order. Roughly 30 minutes, most of
it waiting for `apt`.

Assumes: Ubuntu 24.04 or Debian 12, root or sudo access, a domain on
Cloudflare. Adjust package names for other distributions; nothing here is
Ubuntu-specific except `apt` and `ufw`.

---

## 0. Before you touch the server

**Create the Cloudflare API token.** *My Profile → API Tokens → Create Token →
Edit zone DNS*:

```
Permissions:      Zone / DNS  / Edit
                  Zone / Zone / Read
Zone Resources:   Include / Specific zone / yourdomain.com
```

Copy it once — Cloudflare will not show it again. **Not** the Global API Key:
that is account-wide, cannot be scoped, and cannot be revoked without breaking
everything else that uses it.

**Decide your DNS records.** For each site, an `A` record to the VPS IPv4,
proxied (orange cloud). The Traefik dashboard hostname too.

**Do not add `AAAA` records unless the VPS actually has working IPv6.** A stale
or half-configured `AAAA` means Cloudflare tries IPv6 first and your sites
intermittently fail in ways that look like the origin is down. If you do add
one, the Cloudflare IPv6 ranges in `config/traefik.yml` are what keep client IPs
correct — they are already there.

Certificates come from DNS-01, so the records do not need to resolve to a
working server before you start. You can issue certificates first and point
traffic later.

---

## 1. First ten minutes on the box

```bash
ssh root@<ip>

apt update && apt -y upgrade
apt -y install ca-certificates curl gnupg git make ufw fail2ban \
               unattended-upgrades chrony

# A non-root user for everything from here on.
adduser --gecos "" deploy
usermod -aG sudo deploy
rsync --archive --chown=deploy:deploy ~/.ssh /home/deploy/
```

**Time sync matters more than it looks.** `chrony` is in that list because TLS
certificate validation, ACME nonces and any TOTP you add later all fail on a
skewed clock, and each fails with an unrelated-looking error.

Lock down SSH — in `/etc/ssh/sshd_config`:

```
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
```

```bash
systemctl restart ssh
```

**Open a second terminal and confirm `ssh deploy@<ip>` works before closing the
first one.** Locking yourself out of a VPS means a rescue console.

Firewall:

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw --force enable
```

Unattended security updates:

```bash
dpkg-reconfigure -plow unattended-upgrades
```

---

## 2. Docker

From Docker's own repository, not the distro's — the distro package is usually
several minor versions behind and Compose v2 may be missing.

```bash
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  > /etc/apt/sources.list.d/docker.list

apt update
apt -y install docker-ce docker-ce-cli containerd.io \
               docker-buildx-plugin docker-compose-plugin

usermod -aG docker deploy
```

`docker` group membership is root-equivalent — anyone in it can start a
privileged container that mounts `/`. Only give it to accounts you would give
root to.

**Set daemon-wide log rotation** in `/etc/docker/daemon.json`:

```json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "5" },
  "live-restore": true
}
```

```bash
systemctl restart docker
```

Without this, any container whose compose file forgets `logging:` grows an
unbounded log until the disk fills. It is the most common way a small VPS dies.
`live-restore` keeps containers running across a Docker daemon restart.

---

## 3. The firewall trap

**`ufw status` does not tell you what is reachable on a Docker host.** Docker
inserts its own iptables rules ahead of ufw's, so a published port can be open
to the internet while ufw reports `deny`. People discover this when a database
they thought was firewalled turns up in someone's scan.

Nothing in this stack publishes a port except Traefik, so the exposure is
small — but verify rather than assume, and check again after adding anything:

```bash
sudo iptables -S DOCKER-USER
sudo ss -ltnp                          # what is actually listening
```

To make ufw authoritative for container ports, add to
`/etc/ufw/after.rules` before the final `COMMIT`:

```
*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -i eth0 -p tcp -m conntrack --ctstate NEW -j DROP
-A DOCKER-USER -j RETURN
COMMIT
```

…then explicitly allow 80/443. Replace `eth0` with your real interface
(`ip -br link`). Test from off-box with `nmap` before you trust it.

Simpler and stronger: a **Cloudflare Tunnel** instead of open ports at all.
Then the origin has no inbound listener, the IP cannot be found, and this whole
section stops applying. Worth considering on a rebuild.

---

## 4. Traefik

```bash
su - deploy
sudo mkdir -p /opt/traefik && sudo chown deploy:deploy /opt/traefik
git clone <your-repo> /tmp/php-base
cp -r /tmp/php-base/traefik/. /opt/traefik/
cd /opt/traefik

docker network create proxy
make init
```

Edit the placeholders — `make doctor` will flag any you miss:

| File | Change |
|---|---|
| `.env` | `TRAEFIK_DOMAIN=traefik.yourdomain.com` |
| `config/traefik.yml` | `acme.email` — **twice**, both resolvers |
| `config/dynamic/middlewares.yml` | `cors` origin regex → your domain |
| `config/dynamic/middlewares.yml` | `ipallowlist-admin.sourceRange` → add your egress IP |

For `ipallowlist-admin`, find your egress address with `curl -s ifconfig.me`
from your laptop. If it is dynamic, leave the private ranges only and reach the
dashboard through an SSH tunnel:

```bash
ssh -L 8443:127.0.0.1:443 deploy@<ip>
```

Then credentials:

```bash
make token                      # paste the Cloudflare token, not echoed
make htpasswd USER=admin        # dashboard login
```

---

## 5. The first certificate — staging first

Uncomment in `config/traefik.yml`, under **both** resolvers:

```yaml
      caServer: https://acme-staging-v02.api.letsencrypt.org/directory
```

Let's Encrypt allows **5 duplicate certificates per week** per exact domain set.
A typo in a rule, a wrong token, a DNS record pointing elsewhere — each burns
one. Hit the limit and you cannot issue for *days*, on a server you are trying
to bring up.

```bash
make check     # parses configs, boots Traefik, fails on any error
make up
make logs      # watch the DNS challenge
```

You want to see `Certificates obtained successfully`. Your browser will warn
about an untrusted issuer — that is correct for staging.

If the challenge hangs or times out:

```bash
make doctor    # checks token file mode and trailing whitespace first
```

A trailing newline in the token file is the most common cause, and Traefik
reports it only as a challenge timeout. `make token` avoids it.

Once it works, comment `caServer` back out, then:

```bash
rm certs/acme-*.json     # staging certs and account cannot be reused
make restart
make certs               # confirm real certificates
```

---

## 6. Verify

```bash
make doctor
```

Everything should pass except the placeholder warnings you chose to leave. Then
the check that matters:

```bash
make doctor https://yourdomain.com
```

It sends a forged `X-Forwarded-For` and then reads Traefik's access log to see
what was actually recorded. If the forged address comes back, `trustedIPs` is
wrong and every rate limit, login throttle and IP ban on the host is bypassable
with one header.

Run it **on the server** — it needs Docker access to read the log — but give it
the **public URL**, never `127.0.0.1`. The request has to leave the box and come
back through Cloudflare and the `:443` entryPoint for the trust decision to be
exercised at all. Against loopback it passes no matter how wrong the config is,
because nginx and Traefik both handle a local request differently.

Also confirm in Cloudflare: **SSL/TLS mode must be Full (strict)**. *Flexible*
means Cloudflare speaks HTTPS to the browser and plain HTTP to Traefik, your
app generates `http://` URLs, Cloudflare rewrites them, and you get an infinite
redirect loop that reads as an application bug. See
[`../docs/reverse-proxy.md`](../docs/reverse-proxy.md) for the other four
Cloudflare behaviours that break PHP apps.

---

## 7. First application

```bash
sudo mkdir -p /opt/apps/lms && sudo chown deploy:deploy /opt/apps/lms
cd /opt/apps/lms
cp -r /tmp/php-base/apps/moodle52/. .
cp .env.example .env && $EDITOR .env
```

Add the routing labels — see [`LABELS.md`](LABELS.md) — then:

```bash
docker compose -f compose.prod.yml up -d --build
docker compose -f compose.prod.yml --profile ops run --rm install
cd /opt/traefik && make doctor          # should now list the new container
```

Nothing is registered on the Traefik side. The container declares its own route
and Traefik picks it up from the Docker events stream within a second.

---

## 8. Ongoing

```cron
# Cloudflare adds IP ranges. When it does and the config has not been updated,
# the new edge IPs are untrusted, Traefik overwrites X-Forwarded-For, and every
# backend starts seeing Cloudflare as the client. Nothing logs an error.
0 6 * * 1  cd /opt/traefik && make cf-ips || mail -s "traefik: cloudflare IPs changed" you@example.com

# Certificate expiry, in case a renewal has been quietly failing.
0 7 * * *  cd /opt/traefik && make certs

# The ACME store holds your account key and every certificate's private key.
0 3 * * *  cd /opt/traefik && make backup && rclone move traefik-state-*.tgz remote:backups/
```

Updates:

```bash
cd /opt/traefik && make pull && make check && make up
```

Always `make check` between `pull` and `up`. Traefik has changed dynamic-config
schemas across minor versions before, and the failure mode is `:443` accepting
connections and serving nothing.

**Back up `/opt/traefik/certs/` and `/opt/traefik/secrets/`.** Losing the ACME
store is not fatal but re-issues every certificate, and the weekly duplicate
limit applies. `make backup` tars both; they contain private keys, so store the
tarball encrypted and off the host.

---

## Ordering that matters

A few of these are only obvious in hindsight:

1. **Verify SSH as the new user before disabling root login.** Everything else
   here is recoverable over SSH; this one is not.
2. **`daemon.json` log rotation before any application starts.** Retrofitting it
   means restarting every container.
3. **Staging ACME before production.** The rate limit is per-week and it is
   reached during exactly the fumbling you do on a fresh box.
4. **`make check` before `make up`, every time.** Traefik's characteristic
   failure is a config that starts cleanly, logs nothing, and serves nothing.
5. **The spoofing test against the public URL, not `127.0.0.1`.** The request
   has to traverse the real path — Cloudflare, then the `:443` entryPoint — or
   the trust decision is never exercised and the test passes regardless.
