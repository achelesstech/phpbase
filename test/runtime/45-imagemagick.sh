# shellcheck shell=bash
# imagemagick — /etc/ImageMagick-7/policy.xml (spec §7.8): the format
# allowlist and the RAM cap per operation. A dedicated hardened container
# (--memory 1g): the failure cases are the ones that used to OOM-kill a
# worker, and the OOM count it checks must be this container's alone.
# The cases live in test/public/imagick.php.

info "ImageMagick policy — format allowlist and RAM cap (hardened, --memory 1g)"
IM="$(start imagemagick "$FIXTURE_TAG")"
wait_health "$IM" || bad "imagemagick container never became healthy"
# im_case NAME — imagick.php's output for one case; empty when the request
# fails (e.g. 502 after a worker was killed), so the checks below report that.
im_case() { get_path "$IM" "/imagick.php?case=$1" --max-time 120 || true; }
# im_field BODY KEY — the value of the "KEY:" line in BODY (exact key).
im_field() { awk -F: -v k="$2" '$1 == k { print substr($0, length(k) + 2); exit }' <<<"$1"; }

rt="$(im_case roundtrip)"
failed=()
for f in JPEG PNG GIF WEBP AVIF HEIC BMP ICO; do
    r="$(im_field "$rt" "roundtrip.$f")"
    [[ "$r" == ok ]] || failed+=("${f}=${r:-no output}")
done
[[ ${#failed[@]} -eq 0 ]] && ok "JPEG, PNG, GIF, WEBP, AVIF, HEIC, BMP and ICO round-trip through Imagick" \
    || bad "round-trip: ${failed[*]}"

bl="$(im_case blocked)"
failed=()
for c in msl mvg svg msvg https text ps eps pdf xps ephemeral label; do
    r="$(im_field "$bl" "blocked.$c")"
    # ephemeral: no such coder in this build, so the prefix is inert (the file
    # is read by its magic bytes and kept); refused if the coder ever appears.
    [[ "$r" == refused || ( "$c" == ephemeral && "$r" == inert ) ]] || failed+=("${c}=${r:-no output}")
done
[[ ${#failed[@]} -eq 0 ]] && ok "MSL, MVG, SVG, MSVG, HTTPS, TEXT, PS, EPS, PDF, XPS, EPHEMERAL and LABEL are refused" \
    || bad "not refused: ${failed[*]}"

r="$(im_field "$(im_case photo24)" photo24)"
[[ "$r" == ok ]] && ok "a 24-megapixel JPEG (6000×4000, a phone photo) thumbnails to 400 px" || bad "photo24: ${r:-no output}"

wide="$(im_case wide)"
w_png="$(im_field "$wide" wide.png)"
w_gif="$(im_field "$wide" wide.gif)"
if [[ "$w_gif" == *"width or height exceeds limit"* \
      && ( "$w_png" == *"width or height exceeds limit"* || "$w_png" == *"Invalid IHDR data"* ) ]]; then
    ok "20000×20000 is rejected by the width/height limit (GIF by ImageMagick, PNG by libpng with the same limits)"
else
    bad "wide: png='${w_png:-no output}' gif='${w_gif:-no output}'"
fi

t0="$(date +%s%N)"
r="$(im_field "$(im_case bomb16k)" bomb16k)"
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
[[ "$r" == *"cache resources exhausted"* && "$ms" -lt 10000 ]] \
    && ok "a 16384×16384 PNG fails with 'cache resources exhausted' in ${ms} ms" \
    || bad "bomb16k: '${r:-no output}' after ${ms} ms"

state="$(docker inspect -f '{{.State.Status}}' "$IM")"
events="$(docker exec "$IM" cat /sys/fs/cgroup/memory.events 2>/dev/null || true)"
[[ "$state" == running && "$events" == *"oom_kill 0"* ]] \
    && ok "nothing was OOM-killed (container running, oom_kill 0)" \
    || bad "OOM: state=${state} $(tr '\n' ' ' <<<"$events")"

r="$(im_field "$(im_case gd)" gd)"
[[ "$r" == ok ]] && ok "GD is unaffected: imagecreatetruecolor(6000, 4000)" || bad "gd: ${r:-no output}"
