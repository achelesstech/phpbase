<?php
// Container-style wp-config.php: every setting from the environment, so the
// file can be baked into the image ROOT-owned and read-only.
define('DB_NAME',     getenv('WORDPRESS_DB_NAME') ?: 'wordpress');
define('DB_USER',     getenv('WORDPRESS_DB_USER') ?: 'wordpress');
define('DB_PASSWORD', getenv('WORDPRESS_DB_PASSWORD') ?: '');
define('DB_HOST',     getenv('WORDPRESS_DB_HOST') ?: 'db');
define('DB_CHARSET',  'utf8mb4');
define('DB_COLLATE',  '');
$table_prefix = 'wp_';

foreach (['AUTH_KEY', 'SECURE_AUTH_KEY', 'LOGGED_IN_KEY', 'NONCE_KEY',
          'AUTH_SALT', 'SECURE_AUTH_SALT', 'LOGGED_IN_SALT', 'NONCE_SALT'] as $k) {
    define($k, getenv('WORDPRESS_' . $k) ?: hash('sha256', $k . (getenv('WORDPRESS_DB_PASSWORD') ?: '')));
}

define('WP_HOME',    getenv('WORDPRESS_URL') ?: 'http://localhost:8080');
define('WP_SITEURL', getenv('WORDPRESS_URL') ?: 'http://localhost:8080');
define('DISALLOW_FILE_EDIT', true);
define('DISALLOW_FILE_MODS', true);   // code comes from the image
define('DISABLE_WP_CRON', true);      // php-base-every runs wp cron instead
define('WP_DEBUG', false);

if (!defined('ABSPATH')) {
    define('ABSPATH', __DIR__ . '/');
}
require_once ABSPATH . 'wp-settings.php';
