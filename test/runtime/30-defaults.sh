# shellcheck shell=bash
# defaults — the production PHP ini defaults.
# shellcheck disable=SC2154  # body is set by 00-boot.sh.

info "production PHP defaults (no php.ini ships in the official image)"
[[ "$(field zend_assertions)" == "-1" ]] && ok "zend.assertions = -1 (compiled-in default runs every assert())" || bad "zend.assertions=$(field zend_assertions)"
[[ "$(field exception_ignore_args)" == "1" ]] && ok "zend.exception_ignore_args on (no secrets in stack traces)" || bad "exception_ignore_args=$(field exception_ignore_args)"
[[ "$(field request_order)" == "GP" ]] && ok "request_order = GP (cookies cannot shadow POST in \$_REQUEST)" || bad "request_order=$(field request_order)"
[[ "$(field upload_progress)" == "" || "$(field upload_progress)" == "0" ]] && ok "session.upload_progress disabled (PHP advisory 2026-10-23)" || bad "upload_progress=$(field upload_progress)"
[[ "$(field max_input_vars)" -ge 5000 ]] && ok "max_input_vars >= 5000 (Moodle environment check)" || bad "max_input_vars=$(field max_input_vars)"
[[ "$(field jit)" == "disable" ]] && ok "OPcache JIT off by default" || bad "jit=$(field jit)"
