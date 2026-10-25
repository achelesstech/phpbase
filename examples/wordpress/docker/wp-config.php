<?php
// =============================================================================
// wp-config.php — every setting from the environment (.env, see .env.example)
// =============================================================================
// Baked into the image ROOT-owned, so nothing is generated at start and the
// same file serves app, scheduler, migrate and every `wp` command. A missing
// required setting stops the request with a message naming it.
// =============================================================================

$wp_env = static function (string $name, ?string $default = null): string {
    $value = getenv($name);
    if ($value === false || $value === '') {
        if ($default === null) {
            throw new RuntimeException("wp-config.php: {$name} is not set (see .env.example)");
        }
        return $default;
    }
    return $value;
};

// ── Database ─────────────────────────────────────────────────────────────────
define('DB_NAME',     $wp_env('WORDPRESS_DB_NAME', 'wordpress'));
define('DB_USER',     $wp_env('WORDPRESS_DB_USER', 'wordpress'));
define('DB_PASSWORD', $wp_env('WORDPRESS_DB_PASSWORD'));
define('DB_HOST',     $wp_env('WORDPRESS_DB_HOST', 'db'));
define('DB_CHARSET',  'utf8mb4');
define('DB_COLLATE',  '');
$table_prefix = $wp_env('WORDPRESS_TABLE_PREFIX', 'wp_');

// ── Keys and salts ───────────────────────────────────────────────────────────
// All eight derived from one secret. Changing it logs everyone out.
$wp_secret = $wp_env('WORDPRESS_SECRET');
if (strlen($wp_secret) < 32) {
    throw new RuntimeException('wp-config.php: WORDPRESS_SECRET must be at least 32 characters');
}
foreach (['AUTH_KEY', 'SECURE_AUTH_KEY', 'LOGGED_IN_KEY', 'NONCE_KEY',
          'AUTH_SALT', 'SECURE_AUTH_SALT', 'LOGGED_IN_SALT', 'NONCE_SALT'] as $wp_key) {
    define($wp_key, hash_hmac('sha256', $wp_key, $wp_secret));
}

// ── URL ──────────────────────────────────────────────────────────────────────
// The public URL, scheme included. Traefik terminates TLS; nginx passes
// HTTPS=on from X-Forwarded-Proto, so is_ssl() is right without any proxy code.
$wp_url = rtrim($wp_env('WORDPRESS_URL'), '/');
define('WP_HOME',    $wp_url);
define('WP_SITEURL', $wp_url);

// ── Immutable code ───────────────────────────────────────────────────────────
// Core, themes and plugins come from the image and are root-owned: no
// installs, updates or file editor from the admin. Commit them instead.
define('DISALLOW_FILE_MODS', true);
// The scheduler service runs `wp cron event run --due-now` every minute.
define('DISABLE_WP_CRON', true);

// ── Debugging ────────────────────────────────────────────────────────────────
define('WP_ENVIRONMENT_TYPE', $wp_env('WORDPRESS_ENVIRONMENT_TYPE', 'production'));
define('WP_DEBUG', filter_var($wp_env('WORDPRESS_DEBUG', 'false'), FILTER_VALIDATE_BOOLEAN));
define('WP_DEBUG_DISPLAY', WP_DEBUG);
// The root filesystem is read-only: PHP's error log (container output) only.
define('WP_DEBUG_LOG', false);

unset($wp_env, $wp_secret, $wp_key, $wp_url);

if (!defined('ABSPATH')) {
    define('ABSPATH', __DIR__ . '/');
}
require_once ABSPATH . 'wp-settings.php';
