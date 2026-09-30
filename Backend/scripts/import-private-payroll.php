<?php

declare(strict_types=1);

// Run explicitly during a restore: php scripts/import-private-payroll.php /path/to/old/Backend
// No source is executed; personal values are written only to ignored private storage.
if (PHP_SAPI !== 'cli' || count($argv) !== 2) {
    fwrite(STDERR, "Usage: php scripts/import-private-payroll.php <original-Backend-directory>\n");
    exit(1);
}

$source = realpath($argv[1]);
$backend = dirname(__DIR__);
$target = $backend.'/storage/app/private';

if ($source === false || ! is_dir($source)) {
    fwrite(STDERR, "The original Backend directory does not exist.\n");
    exit(1);
}

$pfSource = $source.'/app/Support/data/may-2026-pf-employees.json';
$salarySource = $source.'/app/Support/PfSalaryBreakdown.php';
$targets = ['may-2026-pf-employees.json', 'pf-salary-overrides.json', 'active-members.csv'];

foreach ($targets as $name) {
    if (file_exists($target.'/'.$name)) {
        fwrite(STDERR, "Private payroll files already exist; back them up and restore manually to avoid overwriting data.\n");
        exit(1);
    }
}

if (! is_file($pfSource) || ! is_file($salarySource)) {
    fwrite(STDERR, "The original payroll allowlist or salary helper is missing. Restore private files manually.\n");
    exit(1);
}

try {
    $pf = json_decode((string) file_get_contents($pfSource), true, flags: JSON_THROW_ON_ERROR);

    if (! is_array($pf) || ! is_array($pf['employees'] ?? null)) {
        throw new RuntimeException('The original PF file has an unsupported format.');
    }

    $salary = (string) file_get_contents($salarySource);

    if (! preg_match('/private const BASIC_DA_BY_EMPLOYEE = \[(.*?)\n    \];/s', $salary, $block)) {
        throw new RuntimeException('The original salary override format is unsupported.');
    }

    preg_match_all("/'([^']+)' => \\['basic' => (\\d+), 'da' => (\\d+)\\]/", $block[1], $matches, PREG_SET_ORDER);
    $overrides = [];

    foreach ($matches as $match) {
        $overrides[$match[1]] = ['basic' => (int) $match[2], 'da' => (int) $match[3]];
    }

    if ($overrides === []) {
        throw new RuntimeException('No salary overrides were found. Restore the configuration manually.');
    }

    $csvName = $pf['activeMembersFile'] ?? null;
    $csvSource = is_string($csvName) ? realpath($source.'/'.$csvName) : false;
    $sourcePrefix = rtrim(str_replace('\\', '/', $source), '/').'/';
    $hasCsv = $csvSource !== false
        && str_starts_with(str_replace('\\', '/', $csvSource), $sourcePrefix)
        && is_file($csvSource);
    $pf['activeMembersFile'] = 'storage/app/private/active-members.csv';
    unset($pf['empIdResolutionCommand']);

    if (! is_dir($target) && ! mkdir($target, 0700, true) && ! is_dir($target)) {
        throw new RuntimeException('Could not create private payroll storage.');
    }

    foreach (['may-2026-pf-employees.json' => $pf, 'pf-salary-overrides.json' => (object) $overrides] as $name => $data) {
        if (file_put_contents($target.'/'.$name, json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR).PHP_EOL) === false) {
            throw new RuntimeException('Could not write private payroll configuration.');
        }

        @chmod($target.'/'.$name, 0600);
    }

    if ($hasCsv) {
        if (! copy($csvSource, $target.'/active-members.csv')) {
            throw new RuntimeException('Could not copy the private active-members file.');
        }

        @chmod($target.'/active-members.csv', 0600);
    }

    fwrite(STDOUT, "Private payroll configuration imported. Back up storage/app/private securely; never commit it.\n");
} catch (Throwable $exception) {
    fwrite(STDERR, $exception->getMessage()."\n");
    exit(1);
}
