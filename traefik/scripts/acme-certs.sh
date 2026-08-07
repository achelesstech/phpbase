#!/usr/bin/env bash
# List the certificates Traefik has issued, with expiry.
#
# The ACME store is a JSON blob, not a directory of PEMs, so `openssl x509`
# cannot read it directly — the certificate is a base64 field inside it.
set -euo pipefail
cd "$(dirname "$0")/.."

shopt -s nullglob
files=(certs/acme-*.json)
if [ ${#files[@]} -eq 0 ]; then
    echo "no ACME store yet — Traefik has not issued anything"
    exit 0
fi

python3 - "${files[@]}" <<'PY'
import base64, json, re, subprocess, sys

rows = []
for path in sys.argv[1:]:
    try:
        data = json.load(open(path)) or {}
    except (ValueError, OSError):
        print(f"{path}: empty or unreadable")
        continue
    for resolver, body in data.items():
        for cert in (body.get("Certificates") or []):
            main = cert["domain"].get("main", "?")
            sans = cert["domain"].get("sans") or []
            expiry = "?"
            try:
                pem = base64.b64decode(cert["certificate"])
                out = subprocess.run(
                    ["openssl", "x509", "-noout", "-enddate"],
                    input=pem, capture_output=True, check=True,
                ).stdout.decode()
                expiry = out.split("=", 1)[1].strip()
            except Exception:
                pass
            rows.append((resolver, main, len(sans), expiry))

if not rows:
    print("ACME store exists but holds no certificates yet")
for resolver, main, nsans, expiry in sorted(rows, key=lambda r: r[1]):
    print(f"{resolver:<14} {main:<40} sans={nsans:<3} expires {expiry}")
PY
