# shellcheck shell=bash
# extensions — the union Laravel, Drupal, Moodle and WordPress need, and the
# libraries behind them.
# shellcheck disable=SC2154  # body is set by 00-boot.sh.

info "extensions — the union Laravel, Drupal, Moodle and WordPress need"
exts="$(field extensions)"
expected=(apcu bcmath ctype curl dom exif fileinfo gd gmp iconv igbinary imagick intl ldap mbstring memcached
          mysqli openssl pcntl pdo_mysql pdo_pgsql pdo_sqlite pgsql redis session simplexml soap sockets
          sodium tokenizer uploadprogress xml xmlreader xmlwriter zip zlib "zend opcache")
missing=()
for ext in "${expected[@]}"; do
    [[ ",${exts}," == *",${ext},"* ]] || missing+=("$ext")
done
[[ ${#missing[@]} -eq 0 ]] && ok "all ${#expected[@]} expected extensions loaded" || bad "missing: ${missing[*]}"
if grep -qiE 'warning|unable to load' <<<"$(docker exec "$APP" php -m 2>&1)"; then bad "php -m prints load warnings"; else ok "php -m loads cleanly"; fi
[[ "$(field argon2id)" == "yes" ]] && ok "argon2id password hashing (Drupal 12 default)" || bad "no argon2id"
[[ "$(field iconv_translit)" == Zlutouck* && "$(field iconv_translit)" != *'?'* ]] && ok "iconv //TRANSLIT works (GNU libiconv, not musl): $(field iconv_translit)" || bad "iconv translit: $(field iconv_translit)"
[[ "$(field intl_bdt)" == *৳* ]] && ok "intl has full ICU data (bn_BD currency: $(field intl_bdt))" || bad "intl_bdt=$(field intl_bdt)"
[[ "$(field imagick_formats)" == "JPEG,PNG,GIF,WEBP,HEIC,AVIF" ]] && ok "Imagick reads JPEG/PNG/GIF/WebP/HEIC/AVIF (WordPress HEIC uploads)" || bad "Imagick formats: $(field imagick_formats)"
[[ "$(field gd_webp_avif)" == "webp,avif" ]] && ok "GD writes WebP and AVIF" || bad "GD: $(field gd_webp_avif)"
[[ "$(field redis_codecs)" == "igbinary,zstd,lz4" ]] && ok "phpredis built with igbinary + zstd + lz4" || bad "redis codecs: $(field redis_codecs)"
[[ "$(field memcached_igbinary)" == "yes" ]] && ok "memcached built with igbinary" || bad "memcached igbinary: $(field memcached_igbinary)"
