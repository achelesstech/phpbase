<?php
// =============================================================================
// config.php — Moodle on php-base. Baked into the image, root-owned; every
// value that differs per site comes from the environment (.env).
// =============================================================================
unset($CFG);
global $CFG;
$CFG = new stdClass();

$env = static function (string $name, ?string $default = null): string {
    $value = getenv($name);
    if ($value !== false && $value !== '') {
        return $value;
    }
    if ($default === null) {
        throw new RuntimeException("config.php: set {$name} in .env");
    }
    return $default;
};

$CFG->dbtype    = 'pgsql';
$CFG->dblibrary = 'native';
$CFG->dbhost    = $env('DB_HOST', 'db');
$CFG->dbname    = $env('DB_DATABASE', 'moodle');
$CFG->dbuser    = $env('DB_USERNAME', 'moodle');
$CFG->dbpass    = $env('DB_PASSWORD');
$CFG->prefix    = 'mdl_';
$CFG->dboptions = ['dbpersist' => false, 'dbport' => (int) $env('DB_PORT', '5432')];

// https://<APP_DOMAIN> in production, http://localhost:8080 in development.
// No trailing slash.
$CFG->wwwroot  = rtrim($env('MOODLE_WWWROOT'), '/');
// The moodle.conf preset serves /dataroot/ from this fixed path.
$CFG->dataroot = '/var/moodledata';
$CFG->admin    = 'admin';
// One user (www-data) writes moodledata: nothing for "other".
$CFG->directorypermissions = 02770;

// Traefik terminates TLS. nginx already passes the forwarded scheme and port
// on; sslproxy makes Moodle treat every request as https even without them.
$CFG->sslproxy = str_starts_with($CFG->wwwroot, 'https://');
// The client address: REMOTE_ADDR only (3 = skip X-Forwarded-For and
// Client-IP). nginx sets REMOTE_ADDR from X-Forwarded-For, trusting only
// private ranges (Traefik on the Docker network) and Cloudflare's edge, so a
// forged header cannot pick the address Moodle logs, rate-limits and locks out.
$CFG->getremoteaddrconf = 3;

// Moodle 5.1+ Routing Engine: the preset falls back to /r.php.
$CFG->routerconfigured = true;
// nginx serves moodledata files itself (the preset's internal /dataroot/).
$CFG->xsendfile = 'X-Accel-Redirect';
$CFG->xsendfilealiases = ['/dataroot/' => $CFG->dataroot];

// Cron runs in the scheduler container, never over the web.
$CFG->cronclionly = true;
// The code is immutable: plugins and updates arrive with a new image.
$CFG->disableupdateautodeploy = true;
// Executable paths are fixed here and cannot be changed from the admin UI.
$CFG->preventexecpath = true;
$CFG->pathtophp = '/usr/local/bin/php';
$CFG->pathtogs  = '/usr/bin/gs';

unset($env);
require_once(__DIR__ . '/public/lib/setup.php');
