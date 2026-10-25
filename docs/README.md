# Documentation

The [repository README](../README.md) has the tags and a quick start. The
copy-to-start examples are in [`examples/`](../examples/).

## The image

| Document | What it covers |
|---|---|
| [`image.md`](image.md) | contents, the runtime contract, roles, presets, the healthcheck, every environment variable, tuning |
| [`security.md`](security.md) | threat model, the hardened run flags, what the tests prove, the ImageMagick policy and how to ship your own |
| [`migrating-from-v1.md`](migrating-from-v1.md) | every breaking change from v1 and what to do about it, and the steps for FarmBook and HQ |

## Running it

| Document | What it covers |
|---|---|
| [`reverse-proxy.md`](reverse-proxy.md) | running behind Traefik and Cloudflare: the trusted-IP chain, keep-alive and timeouts, the `/tmp` tmpfs, which certificate resolver, and the Cloudflare behaviours that break PHP apps |
| [`publishing.md`](publishing.md) | how the image is built and published: Docker Hub setup, the secrets, the watcher, Renovate, verifying a signature |
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
