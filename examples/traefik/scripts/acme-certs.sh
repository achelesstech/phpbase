#!/usr/bin/env bash
# List the certificates Traefik has issued, with expiry, and fail on any that
# expire soon.
#
#   ./scripts/acme-certs.sh                       # certs/acme-*.json, 21 days
#   ./scripts/acme-certs.sh --warn-days 30
#   ./scripts/acme-certs.sh --warn-days 21 path/to/acme.json ...
#
# Exits 1 if any certificate expires within --warn-days (default 21), if a
# certificate's expiry cannot be read, or if a store cannot be read or parsed
# (an empty store means nothing issued yet, and is fine). Traefik renews a
# 90-day certificate 30 days before it expires, so one inside 21 days means
# renewal has been failing for over a week.
#
# Let's Encrypt no longer emails expiry warnings, so this is the warning: run
# it from root's crontab (Traefik writes the stores as root, mode 0600) or
# watch the Prometheus metric traefik_tls_certs_not_after.
#
# The ACME store is a JSON blob, not a directory of PEMs, so `openssl x509`
# cannot read it directly — the certificate is a base64 field inside it.
set -euo pipefail

warn_days=21
files=()
while [ $# -gt 0 ]; do
    case "$1" in
        --warn-days)
            [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "usage: $0 [--warn-days N] [acme.json ...]" >&2; exit 2; }
            warn_days="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        -*)
            echo "unknown option: $1" >&2
            echo "usage: $0 [--warn-days N] [acme.json ...]" >&2
            exit 2
            ;;
        *)
            files+=("$1")
            shift
            ;;
    esac
done

if [ ${#files[@]} -eq 0 ]; then
    shopt -s nullglob
    files=("$(dirname "$0")"/../certs/acme-*.json)
    shopt -u nullglob
    if [ ${#files[@]} -eq 0 ]; then
        echo "no ACME store yet — Traefik has not issued anything"
        exit 0
    fi
fi

python3 - "$warn_days" "${files[@]}" <<'PY'
import base64, json, subprocess, sys
from datetime import datetime, timezone

warn_days = int(sys.argv[1])
now = datetime.now(timezone.utc)

rows, flagged, bad_stores = [], [], []
for path in sys.argv[2:]:
    # Fail closed: this is the only expiry warning, so a store it cannot read
    # must not look like a store with nothing expiring.
    try:
        with open(path) as f:
            text = f.read()
    except OSError as e:
        print(f"{path}: cannot read ({e.strerror})")
        bad_stores.append(path)
        continue
    if not text.strip():
        # Traefik creates the file empty and fills it on the first issuance.
        print(f"{path}: empty — nothing issued yet")
        continue
    try:
        data = json.loads(text)
        if not isinstance(data, dict) or not all(isinstance(b, dict) for b in data.values()):
            raise ValueError("not an ACME store")
    except ValueError as e:
        print(f"{path}: not a valid ACME store ({e})")
        bad_stores.append(path)
        continue
    for resolver, body in data.items():
        for cert in (body.get("Certificates") or []):
            main = cert["domain"].get("main", "?")
            sans = cert["domain"].get("sans") or []
            try:
                pem = base64.b64decode(cert["certificate"])
                out = subprocess.run(
                    ["openssl", "x509", "-noout", "-enddate"],
                    input=pem, capture_output=True, check=True,
                ).stdout.decode()
                # notAfter=Nov  4 12:00:00 2026 GMT — always English, always GMT.
                end = datetime.strptime(out.split("=", 1)[1].strip(),
                                        "%b %d %H:%M:%S %Y %Z")
                end = end.replace(tzinfo=timezone.utc)
            except Exception:
                rows.append((resolver, main, len(sans), "expiry unreadable"))
                flagged.append(main)
                continue
            days = (end - now).days
            rows.append((resolver, main, len(sans),
                         f"expires {end:%Y-%m-%d} ({days} days)"))
            if days < warn_days:
                flagged.append(main)

if not rows and not bad_stores:
    print("ACME store exists but holds no certificates yet")
for resolver, main, nsans, expiry in sorted(rows, key=lambda r: r[1]):
    print(f"{resolver:<14} {main:<40} sans={nsans:<3} {expiry}")

if flagged:
    print(f"\n{len(flagged)} certificate(s) expire within {warn_days} days or "
          f"cannot be read: {', '.join(sorted(flagged))}")
    print("Traefik renews 30 days ahead, so renewal is probably failing. Check: make logs")
if bad_stores:
    print(f"\n{len(bad_stores)} ACME store(s) could not be read, so their "
          f"certificates were not checked: {', '.join(bad_stores)}")
    print("Traefik writes them as root, mode 0600: run this as root (sudo make certs).")
if flagged or bad_stores:
    sys.exit(1)
PY
