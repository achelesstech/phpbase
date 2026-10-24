<?php
// Container-style config.php: settings from the environment, baked ROOT-owned.
unset($CFG);
global $CFG;
$CFG = new stdClass();

$CFG->dbtype    = 'pgsql';
$CFG->dblibrary = 'native';
$CFG->dbhost    = getenv('MOODLE_DB_HOST') ?: 'db';
$CFG->dbname    = getenv('MOODLE_DB_NAME') ?: 'moodle';
$CFG->dbuser    = getenv('MOODLE_DB_USER') ?: 'moodle';
$CFG->dbpass    = getenv('MOODLE_DB_PASSWORD') ?: '';
$CFG->prefix    = 'mdl_';
$CFG->dboptions = ['dbpersist' => false, 'dbport' => 5432];

$CFG->wwwroot   = getenv('MOODLE_URL') ?: 'http://127.0.0.1:8080';
$CFG->dataroot  = '/var/moodledata';
$CFG->admin     = 'admin';
$CFG->directorypermissions = 02777;

$CFG->routerconfigured = true;
$CFG->sslproxy  = (getenv('MOODLE_SSLPROXY') === 'true');
$CFG->xsendfile = 'X-Accel-Redirect';
$CFG->xsendfilealiases = ['/dataroot/' => $CFG->dataroot];
$CFG->cronclionly = true;
$CFG->pathtophp = '/usr/local/bin/php';

require_once(__DIR__ . '/public/lib/setup.php');
