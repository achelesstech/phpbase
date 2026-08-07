<?php
// Reports what the test needs to assert about the running container.
// One field per line — the assertions anchor with ^...$.
header('Content-Type: text/plain');

$out = [
    'php-ok'       => PHP_VERSION,
    'uid'          => posix_getuid(),
    'gid'          => posix_getgid(),
    'memory_limit' => ini_get('memory_limit'),
    'opcache'      => ini_get('opcache.enable') ? 'on' : 'off',
    'jit'          => ini_get('opcache.jit') ?: 'unset',

    // Set-but-empty HTTPS is the bug `if_not_empty` prevents: code testing
    // isset() would conclude TLS is on and emit https:// URLs over plain HTTP.
    'https_isset'  => isset($_SERVER['HTTPS']) ? 'yes' : 'no',
    'https_value'  => var_export($_SERVER['HTTPS'] ?? null, true),

    // With real_ip configured, this must be the CLIENT address from
    // X-Forwarded-For, not the proxy's address.
    'remote_addr'  => $_SERVER['REMOTE_ADDR'] ?? 'unset',

    'hook_ran'     => file_exists('/tmp/fixture-hook-ran') ? 'yes' : 'no',
    'extensions'   => implode(',', array_map('strtolower', get_loaded_extensions())),
];

foreach ($out as $key => $value) {
    printf("%s:%s\n", $key, $value);
}
