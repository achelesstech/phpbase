<?php

/**
 * @file
 * Drupal settings, read from the environment (examples/drupal on php-base).
 *
 * Baked into the image as web/sites/default/settings.php, root-owned and
 * read-only; compose.yml bind-mounts it there for local development. It holds
 * no secrets: every value comes from the container's environment (.env).
 *
 * No reverse-proxy settings: nginx in php-base already sets REMOTE_ADDR to the
 * client's address (real_ip from the trusted proxy) and HTTPS from
 * X-Forwarded-Proto, so Drupal sees the real client and scheme as they are.
 */

$env = static fn (string $name, string $default = ''): string =>
  (string) (getenv($name) ?: $default);

// ── Database (the compose `db` service) ─────────────────────────────────────
$databases['default']['default'] = [
  'driver' => 'pgsql',
  'namespace' => 'Drupal\\pgsql\\Driver\\Database\\pgsql',
  'autoload' => 'core/modules/pgsql/src/Driver/Database/pgsql/',
  'host' => $env('DB_HOST', 'db'),
  'port' => $env('DB_PORT', '5432'),
  'database' => $env('DB_DATABASE', 'drupal'),
  'username' => $env('DB_USERNAME', 'drupal'),
  'password' => $env('DB_PASSWORD'),
  'prefix' => '',
];

// Required. Drupal refuses to start without one; never change it afterwards
// (it signs one-time login links, form tokens and image-style URLs).
$settings['hash_salt'] = $env('DRUPAL_HASH_SALT');

// ── Host header ──────────────────────────────────────────────────────────────
// Only the public host name is accepted; any other Host gets a 400. Required:
// an empty list would silently accept any Host (cache poisoning, password
// reset links to another domain), so refuse to start instead.
$app_domain = $env('APP_DOMAIN');
if ($app_domain === '') {
  throw new RuntimeException('settings.php: set APP_DOMAIN in .env');
}
$settings['trusted_host_patterns'] = ['^' . preg_quote($app_domain) . '$'];

// ── Files ────────────────────────────────────────────────────────────────────
// public:// is web/sites/default/files (the default) and private:// is
// outside the docroot; each is a volume, and the only writable paths besides
// /tmp. Uploads in flight live in /tmp (a tmpfs).
$settings['file_public_path'] = 'sites/default/files';
$settings['file_private_path'] = '/var/www/html/private';
$settings['file_temp_path'] = '/tmp';

// Configuration lives in the code: export with `drush config:export` in
// development, commit config/sync, and `drush deploy` imports it.
$settings['config_sync_directory'] = '../config/sync';

// Code is immutable: modules and themes arrive with a new image, never
// through the UI.
$settings['allow_authorize_operations'] = FALSE;

// The scheduler service runs `drush cron` every minute; cron at the end of
// page requests (the automated_cron module) would only duplicate it.
$config['automated_cron.settings']['interval'] = 0;

// Local overrides for development only (never baked into the image).
if (file_exists($app_root . '/' . $site_path . '/settings.local.php')) {
  include $app_root . '/' . $site_path . '/settings.local.php';
}
