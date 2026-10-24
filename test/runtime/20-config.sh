# shellcheck shell=bash
# config — PHP_*/FPM_* env rendering and /docker-entrypoint.d hooks.
# shellcheck disable=SC2154  # body is set by 00-boot.sh.

info "runtime configuration"
[[ "$(field memory_limit)" == "333M" ]] && ok "PHP_* env override applied" || bad "memory_limit=$(field memory_limit)"
[[ "$(field session_save_path)" == 'tcp://redis:6379?auth=s3cret&database=2' ]] \
    && ok "an ini value with ?, & and = survives rendering (quoted)" || bad "session.save_path=$(field session_save_path)"
[[ "$(field pcre_backtrack_limit)" == "5000000" ]] && ok "PHP_INI_EXTRA applied" || bad "PHP_INI_EXTRA not applied"
check "FPM pool override rendered into /tmp/php-base" docker exec "$APP" grep -q 'pm.max_children = 7' /tmp/php-base/fpm/zz-runtime.conf
grep -q '^hook_ran:yes$' <<<"$body" && ok "/docker-entrypoint.d hook ran despite having no exec bit" || bad "hook did not run"
if grep -q <<<"$(docker logs "$APP" 2>&1)" 'WARNING: .*writable'; then bad "root-owned hook triggered a writable-hook warning"; else ok "root-owned hook: no warning"; fi
