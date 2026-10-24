# Documentation

The image itself is described in the [repository README](../README.md). The
copy-to-start examples are in [`examples/`](../examples/).

## Running it

| Document | What it covers |
|---|---|
| [`reverse-proxy.md`](reverse-proxy.md) | running behind Traefik and Cloudflare: the trusted-IP chain and the Cloudflare behaviours that break PHP apps |
| [`docker-hub.md`](docker-hub.md) | the text for the Docker Hub page |

## Traefik

For the edge proxy in [`examples/traefik/`](../examples/traefik/).

| Document | What it covers |
|---|---|
| [`traefik/vps-setup.md`](traefik/vps-setup.md) | a bare VPS to serving traffic, in order |
| [`traefik/static-config.md`](traefik/static-config.md) | every static property, and why |
| [`traefik/labels.md`](traefik/labels.md) | the labels an app repository needs |
| [`traefik/audit-previous-config.md`](traefik/audit-previous-config.md) | what changed from the previous config, what was broken, and what was verified |

## Portainer

For the container UI in [`examples/portainer/`](../examples/portainer/).

| Document | What it covers |
|---|---|
| [`portainer/audit-docker-run.md`](portainer/audit-docker-run.md) | what was wrong with the official `docker run` install, and why each change was made |

## Design records

| Document | What it covers |
|---|---|
| [`superpowers/specs/2026-10-24-php-base-v2-design.md`](superpowers/specs/2026-10-24-php-base-v2-design.md) | the php-base v2 design |
| [`superpowers/plans/2026-10-25-php-base-v2.md`](superpowers/plans/2026-10-25-php-base-v2.md) | the php-base v2 implementation plan |
