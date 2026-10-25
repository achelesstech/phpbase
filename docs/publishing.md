# Publishing

How `docker.io/achelesstech/php-base` gets built and published, the one-time
setup, and the routine jobs. The tags themselves are described in the
[README](../README.md#tags); [`docker-hub.md`](docker-hub.md) is the text for
the Docker Hub page.

Two workflows do all of it:

| Workflow | Runs | Does |
|---|---|---|
| [`build-base.yml`](../.github/workflows/build-base.yml) | Mondays 03:23 UTC; on a push to `main` or a pull request that touches the image; by hand; when `watch-upstream` dispatches it | resolve, build, test, publish, sign |
| [`watch-upstream.yml`](../.github/workflows/watch-upstream.yml) | every 6 hours, at minute 17 | checks each published line against upstream and dispatches `build-base` for the lines that changed. Builds nothing itself |

## One-time setup

1. **Create the Docker Hub repository** `achelesstech/php-base` and make it
   **public**. An organisation's default visibility may be private, so check
   it. It must be public because:
   - app images, their CI and their Renovate pull it without credentials;
   - the resolver checks whether a build tag already exists with an
     anonymous call to Docker Hub's API. A private repository's tags are
     invisible to it, so it could reuse a tag that is already published.

   App images are the opposite: they contain your code and must be
   **private** (see [`examples/README.md`](../examples/README.md)).
2. **Create an access token that can push**: a Read & Write personal access
   token from a member account (a bot account is better than a person), or an
   organisation access token. Not the account password.
3. **Add two repository secrets** on GitHub (*Settings → Secrets and
   variables → Actions*):

   | Secret | Value |
   |---|---|
   | `DOCKERHUB_USERNAME` | the account the token belongs to |
   | `DOCKERHUB_TOKEN` | the token |

   Every job that pulls or pushes logs in with them whenever they exist,
   including on pull requests. Anonymous Docker Hub pulls are rate-limited
   per IP, and GitHub's runners share IPs. Pull requests from forks get no
   secrets: they build and test without logging in, and never push.
4. **Optional: make the build tags immutable.** On the Docker Hub
   repository, enable immutable tags for

   ```
   ^\d+\.\d+\.\d+-\d{8}(\.\d+)?(-dev)?$
   ```

   That is `8.4.27-20261026`, `8.4.27-20261026.2` and their `-dev` twins. The
   resolver never reuses one; this makes the registry refuse it too.
5. **Run it once by hand:** *Actions → build-base → Run workflow*, with
   `publish` ticked. Check the tags on Docker Hub, then check the signature
   ([below](#verifying-an-image)).
6. **Install the Renovate GitHub app** on the repository, if it isn't
   installed yet. It reads [`renovate.json`](../renovate.json).

The workflows declare the token permissions they need (`id-token: write` to
sign, `actions: write` for the watcher to dispatch, `issues: write` to report
a failure) in the workflow files.

## What a build does

```
resolve ─► build (line × arch, native runners) ─► publish (per line) ─► guards ─► report
```

1. **resolve** pins every input to a digest:
   `php:<line>-fpm-alpine` (`-rc-` for the pre-release line), the
   `alpine:<minor>` that PHP image was built on, and Composer. It picks a
   build tag nobody has published (`X.Y.Z-YYYYMMDD`, or the next `.N`), and
   runs the freshness guards:
   - a line **fails** when its upstream PHP is behind a php.net release that
     is more than 3 days old. It is not built, so its tags stay where they
     were;
   - a **warning** when a newer Alpine has been out for more than 14 days,
     when upstream's tag hasn't changed for 30 days, when a pre-release line
     has a GA tag, or when php.net supports a branch `versions.json` doesn't
     list.

   A line whose `eol` date in [`versions.json`](../versions.json) has passed
   is skipped unless the run has `include_eol`.
2. **build** runs on native amd64 and arm64 runners. On a publishing run it
   pushes the runtime and `-dev` images **by digest** (no tag points at them
   yet), pulls that exact digest back, and tests it: size against
   `max_size_mb`, the runtime suite under the hardened flags, the `-dev`
   suite, real Laravel, Drupal, WordPress and Moodle installs (amd64), and
   Trivy (any fixable HIGH or CRITICAL finding fails). Pull requests build
   and test locally and never push.
3. **publish**, per line, only when every platform passed: one multi-arch
   index per variant, tagged with every tag of the line, then signed with
   cosign (keyless, GitHub OIDC). Every image carries an SBOM and provenance
   (`mode=max`). A failure on one line never blocks the others. The job
   summary prints the digest to pin.
4. **guards** fails the run after the healthy lines have published, if a
   freshness guard removed a line.
5. **report**: when a **scheduled** run or a run the **watcher** dispatched
   fails, it opens an issue titled `php-base build failed (weekly run)` or
   `php-base build failed (watcher run)`, or comments on the open one with
   the same title. Otherwise a failing weekly build would only email whoever
   last edited the cron line, and a failing watcher build would email no
   one. The watcher marks its dispatches with `trigger=watcher`; a manual
   dispatch (`trigger` defaults to `manual`) opens no issue, because whoever
   started it is watching.

The 8.6 release candidate is a canary: its failure doesn't fail the run, and
it is tagged (`8.6-rc`, `8.6-rc-dev`) only when it passes.

## The watcher: rebuilds within 6 hours

`watch-upstream` runs `scripts/check-upstream.sh` every 6 hours. For each
stable line that isn't past its `eol` date, it compares the published
`X.Y` with now. The first of these that applies is the line's reason to
rebuild:

| Reason | Meaning |
|---|---|
| `php-image` | `php:<line>-fpm-alpine` has a new digest (its `…upstream-digest` label differs), or the line has never been published |
| `alpine-image` | `alpine:<minor>` has a new digest (the `org.opencontainers.image.base.digest` label differs) |
| `apk-upgrades` | `apk upgrade --simulate`, run as root in the published image, would upgrade a package |

It then dispatches `build-base` with `only=<those lines>` and `publish=true`,
and its job summary shows each line's reason. A failed lookup fails the
watcher instead of reading as "current", so a Docker Hub outage can't hide an
update.

Every CI run reinstalls the OS packages: the `apk upgrade && apk add` layer
is keyed on `PKG_CACHE_BUST`, which CI sets to the date plus the run id, so
an `apk-upgrades` rebuild on the same day as the weekly build really picks up
the new packages instead of reusing the cached layer. (Local builds through
`scripts/build-args.sh` use the date, so they refresh once a day.)

Why: PHP shipped the PHP2Shell fixes on a Wednesday. The Monday build alone
would have published them five days later.

**GitHub disables scheduled workflows in a public repository after 60 days
without activity.** Both workflows then stop, and nothing in them can report
it. Re-enable them under *Actions*.

## Renovate

[`renovate.json`](../renovate.json) in this repository covers:

| What | How |
|---|---|
| PECL extension versions (the `ARG …_VERSION` pins in the `Dockerfile`, each with a `# renovate:` comment) | one grouped PR, "PECL extensions". Its CI run proves the bump on every line and both architectures. Minor and patch bumps merge themselves once CI is green, and the next build ships them; a major bump waits for a human |
| GitHub Actions, pinned by digest | grouped; minor, patch and digest updates merge themselves once CI is green |
| Third-party images in `examples/**` (Postgres, MariaDB, Traefik, the socket proxy, Portainer, Node) | a PR each, never automerged: a database or edge-proxy bump needs someone to read its release notes |

It runs before 06:00 on Mondays. PHP and Alpine are deliberately not in it:
the resolver takes the newest digests on every run. The `php-base` and
app-image references in `examples/` are switched off: they are placeholders,
kept current by the copied project's own `renovate.json`.

`ignorePaths` (`**/node_modules/**`, `.work/**`, `.cache/**`) replaces the
recommended preset's list, which would skip `examples/` and `test/`. Drop it,
or restore the preset's list, and the `examples/**` rules stop matching
anything, with no error.

Each app example has its own `renovate.json` for the app repository. It
keeps both base digests (`PHP_BASE_IMAGE` and `PHP_BASE_DEV_IMAGE`) current
in one PR, and never moves an app to another PHP line on its own. That PR is
how a base rebuild (a CVE fix) reaches the app.

## By hand

*Actions → build-base → Run workflow* takes:

| Input | Default | Use |
|---|---|---|
| `only` | empty: every line | e.g. `8.4,8.5` |
| `publish` | on | off: build and test only |
| `include_eol` | off | also build lines past their `eol` |
| `skip_frameworks` | off | skip the framework installs, for an emergency security rebuild |
| `trigger` | `manual` | `watcher` (set by `watch-upstream`): a failure opens an issue |

From a terminal:

```sh
gh workflow run build-base.yml -f only=8.4 -f publish=true
gh workflow run build-base.yml -f only=8.4 -f skip_frameworks=true   # emergency
```

`make resolve` shows what CI would build right now (digests and tags),
without building. Local builds are `local/php-base:X.Y[-dev]` and are never
pushed: nothing in the `Makefile` pushes.

## Verifying an image

The signature proves the image was built by this repository's `build-base`
workflow:

```sh
cosign verify docker.io/achelesstech/php-base:8.4 \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github.com/achelesstech/phpbase/\.github/workflows/build-base\.yml@'
```

The SBOM and the provenance are attached to the image:

```sh
docker buildx imagetools inspect docker.io/achelesstech/php-base:8.4 --format '{{ json .SBOM }}'
docker buildx imagetools inspect docker.io/achelesstech/php-base:8.4 --format '{{ json .Provenance }}'
```

The labels name every input: `org.opencontainers.image.base.digest` (the
Alpine image) and `io.github.achelesstech.php-base.upstream-digest` (the PHP
image). Inside a container, `php-base-info` prints the same.

## Rolling back

Apps pin the base by digest, so a bad base build reaches an app only when its
Renovate PR is merged. Close it, or revert the merge. Every build also has a
tag that never moves (`8.4.27-20261026`), and its digest stays pullable.
