<?php

namespace Tests\Unit;

use App\Support\SpreadsheetDiskCache;
use App\Support\SpreadsheetImportGuard;
use App\Support\SpreadsheetMemory;
use PhpOffice\PhpSpreadsheet\Spreadsheet;
use PhpOffice\PhpSpreadsheet\Writer\Xlsx;
use PHPUnit\Framework\TestCase;

class SpreadsheetMemorySafetyTest extends TestCase
{
    public function test_disk_cache_round_trips_and_clears_values(): void
    {
        $cache = new SpreadsheetDiskCache();

        $this->assertTrue($cache->set('cell-A1', ['value' => 'AGPL001']));
        $this->assertSame(['value' => 'AGPL001'], $cache->get('cell-A1'));
        $this->assertTrue($cache->has('cell-A1'));
        $this->assertTrue($cache->clear());
        $this->assertFalse($cache->has('cell-A1'));
    }

    public function test_xlsx_can_be_written_with_temporary_disk_cell_cache(): void
    {
        $cache = SpreadsheetMemory::useTemporaryDiskCache();
        $spreadsheet = new Spreadsheet();
        $path = tempnam(sys_get_temp_dir(), 'attica-xlsx-test-');

        try {
            for ($row = 1; $row <= 250; $row++) {
                $spreadsheet->getActiveSheet()->setCellValue('A'.$row, 'EMP-'.$row);
                $spreadsheet->getActiveSheet()->setCellValue('B'.$row, $row);
            }

            (new Xlsx($spreadsheet))->save($path);
            $this->assertGreaterThan(0, filesize($path));
        } finally {
            $spreadsheet->disconnectWorksheets();
            SpreadsheetMemory::release($cache);
            if (is_file($path)) {
                unlink($path);
            }
        }
    }

    public function test_import_guard_rejects_more_than_the_configured_row_limit(): void
    {
        $temporaryPath = tempnam(sys_get_temp_dir(), 'attica-import-test-');
        $path = $temporaryPath.'.csv';
        rename($temporaryPath, $path);
        $handle = fopen($path, 'wb');

        for ($row = 0; $row <= SpreadsheetImportGuard::MAX_ROWS; $row++) {
            fputcsv($handle, ['AGPL'.$row, 'Fixture Person 6'.$row], ',', '"', '');
        }
        fclose($handle);

        try {
            $this->expectException(\RuntimeException::class);
            $this->expectExceptionMessage('Import at most '.SpreadsheetImportGuard::MAX_ROWS.' rows at a time.');
            SpreadsheetImportGuard::rows($path);
        } finally {
            if (is_file($path)) {
                unlink($path);
            }
        }
    }
}
