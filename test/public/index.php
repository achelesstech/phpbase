<?php
// Reports what test/run.sh asserts about the running container.
// One field per line — the assertions anchor with ^...$.
header('Content-Type: text/plain');

if (isset($_GET['sleep'])) {           // slowlog check
    usleep((int) $_GET['sleep'] * 1000000);
    exit("slept\n");
}
if (isset($_GET['exec'])) {            // PHP_DISABLE_FUNCTIONS check
    exit('exec:' . (function_exists('exec') ? 'enabled' : 'disabled') . "\n");
}
if (isset($_GET['log'])) {             // logs check: error_log() must reach docker logs
    error_log((string) $_GET['log']);
    exit("logged\n");
}
if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {   // body-size check
    exit('post_bytes:' . strlen(file_get_contents('php://input')) . "\n");
}

$home = getenv('HOME') ?: '';
$fmt  = class_exists('NumberFormatter') ? new NumberFormatter('bn_BD', NumberFormatter::CURRENCY) : null;
$im   = class_exists('Imagick') ? Imagick::queryFormats() : [];

$out = [
    'php-ok'                => PHP_VERSION,
    'uid'                   => posix_getuid(),
    'gid'                   => posix_getgid(),
    'home'                  => $home,
    'home_writable'         => ($home !== '' && is_writable($home)) ? 'yes' : 'no',
    'memory_limit'          => ini_get('memory_limit'),
    'session_save_path'     => ini_get('session.save_path'),
    'pcre_backtrack_limit'  => ini_get('pcre.backtrack_limit'),
    'opcache'               => ini_get('opcache.enable') ? 'on' : 'off',
    'jit'                   => ini_get('opcache.jit') ?: 'unset',
    'zend_assertions'       => ini_get('zend.assertions'),
    'exception_ignore_args' => ini_get('zend.exception_ignore_args'),
    'request_order'         => ini_get('request_order'),
    'upload_progress'       => ini_get('session.upload_progress.enabled'),
    'max_input_vars'        => ini_get('max_input_vars'),
    'output_buffering'      => ini_get('output_buffering'),

    // Set-but-empty HTTPS is the bug `if_not_empty` prevents.
    'https_isset'           => isset($_SERVER['HTTPS']) ? 'yes' : 'no',
    'https_value'           => var_export($_SERVER['HTTPS'] ?? null, true),
    // With real_ip configured: the CLIENT from X-Forwarded-For, not the proxy.
    'remote_addr'           => $_SERVER['REMOTE_ADDR'] ?? 'unset',

    'hook_ran'              => file_exists('/tmp/fixture-hook-ran') ? 'yes' : 'no',
    'pwned'                 => function_exists('pwned') ? 'yes' : 'no',
    'extensions'            => implode(',', array_map('strtolower', get_loaded_extensions())),

    // Framework-relevant capabilities, not just "extension loaded".
    'argon2id'              => (defined('PASSWORD_ARGON2ID') && str_starts_with(password_hash('x', PASSWORD_ARGON2ID), '$argon2id$')) ? 'yes' : 'no',
    'iconv_translit'        => (string) @iconv('UTF-8', 'ASCII//TRANSLIT', 'Žluťoučký kůň'),
    'intl_bdt'              => $fmt ? $fmt->formatCurrency(1234.5, 'BDT') : 'no-intl',
    'imagick_formats'       => implode(',', array_values(array_intersect(['JPEG', 'PNG', 'GIF', 'WEBP', 'HEIC', 'AVIF'], $im))),
    'gd_webp_avif'          => (function_exists('imagewebp') ? 'webp' : '-') . ',' . (function_exists('imageavif') ? 'avif' : '-'),
    'redis_codecs'          => implode(',', array_filter([
        defined('Redis::SERIALIZER_IGBINARY') ? 'igbinary' : null,
        defined('Redis::COMPRESSION_ZSTD') ? 'zstd' : null,
        defined('Redis::COMPRESSION_LZ4') ? 'lz4' : null,
    ])),
    'memcached_igbinary'    => (class_exists('Memcached') && Memcached::HAVE_IGBINARY) ? 'yes' : 'no',
];

foreach ($out as $key => $value) {
    printf("%s:%s\n", $key, $value);
}
