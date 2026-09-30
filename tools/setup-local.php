<?php

// Run after composer install. This script only initializes an empty local database.
declare(strict_types=1);

function stop(string $message): never
{
    fwrite(STDERR, $message.PHP_EOL);
    exit(1);
}

$backend = dirname(__DIR__).'/Backend';
if (!is_file($backend.'/vendor/autoload.php')) {
    stop('Run composer install --working-dir=Backend first.');
}
foreach (['bootstrap/cache', 'storage/app/public', 'storage/app/private', 'storage/framework/cache/data', 'storage/framework/sessions', 'storage/framework/views', 'storage/logs'] as $directory) {
    if (!is_dir($backend.'/'.$directory) && !mkdir($backend.'/'.$directory, 0775, true)) {
        stop('Cannot create runtime directory: '.$directory);
    }
}
if (!is_file($backend.'/.env')) {
    copy($backend.'/.env.example', $backend.'/.env');
}
if (is_file($backend.'/bootstrap/cache/config.php')) {
    stop('Cached configuration found. Run php artisan config:clear in Backend, then retry.');
}
require $backend.'/vendor/autoload.php';
$app = require $backend.'/bootstrap/app.php';
$kernel = $app->make(Illuminate\Contracts\Console\Kernel::class);
$kernel->bootstrap();
$connection = config('database.connections.mysql');
$database = (string) $connection['database'];
if (!app()->environment('local') || config('database.default') !== 'mysql'
    || !in_array($connection['host'], ['127.0.0.1', 'localhost', '::1'], true)
    || !preg_match('/^attendance_(?:local|repo_verify)[a-zA-Z0-9_]*$/', $database)
    || !empty($connection['url'])) {
    stop('Local setup requires APP_ENV=local, local MySQL, and a database name beginning attendance_local or attendance_repo_verify.');
}
try {
    $pdo = new PDO('mysql:host='.$connection['host'].';port='.$connection['port'].';charset=utf8mb4', $connection['username'], $connection['password'], [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    $pdo->exec('CREATE DATABASE IF NOT EXISTS `'.$database.'` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci');
    $tables = $pdo->query('SHOW TABLES FROM `'.$database.'`')->fetchAll();
    if ($tables !== []) {
        stop('Database is not empty. Setup stopped without changing its tables. Use another empty local database; see README.md.');
    }
} catch (PDOException $e) {
    stop('Cannot prepare local MySQL. Start MySQL and check DB_* in Backend/.env. Driver code: '.$e->getCode());
}

chdir($backend);
function artisan(array $arguments): void
{
    $command = escapeshellarg(PHP_BINARY).' artisan '.implode(' ', array_map('escapeshellarg', $arguments));
    passthru($command, $status);
    if ($status !== 0) {
        stop('Setup stopped. Fix the reported error before continuing.');
    }
}
if (!config('app.key')) {
    artisan(['key:generate', '--force']);
}
artisan(['migrate', '--force']);
artisan(['attendance:setup-demo', '--yes']);
artisan(['storage:link']);
echo PHP_EOL.'Backend ready. Save the generated demo credentials above privately.'.PHP_EOL;
echo 'Build the frontend as described in README.md, then run php artisan serve --host=127.0.0.1 --port=8000 in Backend.'.PHP_EOL;
