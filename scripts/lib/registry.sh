# shellcheck shell=bash
# =============================================================================
# registry.sh — registry lookups that cost Docker Hub one pull each
# =============================================================================
#   . scripts/lib/registry.sh
#   index_of REF              REF's top-level manifest (the index), raw JSON
#   digest_of_index RAW       the digest of that index
#   amd64_image REPO RAW      the linux/amd64 image of that index, as
#                             `imagetools inspect --format '{{json .Image}}'`
#                             prints it for one platform (.config.Env, .config.Labels)
#
# Docker Hub counts every manifest it serves as a pull, against one hourly
# allowance per account (200) or per IP (100). `imagetools inspect --format`
# on a multi-platform ref fetches the whole index and its entries: 9 pulls for
# php:X.Y-fpm-alpine, measured, so a full resolve ran out at its fifth line.
# These fetch one manifest per call. Never use --format on an index here;
# test/scripts/upstream.test.sh's stub refuses it. Nothing else calls
# `imagetools inspect` (test/scripts/registry.test.sh).
# =============================================================================

index_of() {
    docker buildx imagetools inspect --raw "$1"
}

# A manifest's digest is the sha256 of its bytes, which --raw prints unchanged,
# adding no newline. (A manifest whose own bytes ended in one would lose it to
# the command substitution and hash wrong.) A wrong hash could not go unseen:
# every digest is pulled again by @digest, and the registry refuses a digest
# it does not have.
digest_of_index() {
    printf '%s' "$1" | sha256sum | awk '{ print "sha256:" $1 }'
}

amd64_image() {
    local repo="$1" raw="$2" amd64
    amd64="$(jq -re '[.manifests[] | select(.platform.os == "linux" and .platform.architecture == "amd64")][0].digest' <<<"$raw")" \
        || { echo "${repo}: the index has no linux/amd64 image" >&2; return 1; }
    docker buildx imagetools inspect "${repo}@${amd64}" --format '{{json .Image}}'
}
