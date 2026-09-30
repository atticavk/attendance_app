<?php

namespace Tests\Unit;

use App\Http\Controllers\AttendanceController;
use App\Support\SpreadsheetImportGuard;
use Illuminate\Http\Request;
use PhpOffice\PhpSpreadsheet\Spreadsheet;
use PhpOffice\PhpSpreadsheet\Writer\Xls;
use ReflectionMethod;
use Tests\TestCase;

class CompatibilityRestorationTest extends TestCase
{
    public function test_desktop_pointer_request_uses_logged_in_branch_only_mode(): void
    {
        $controller = app(AttendanceController::class);
        $method = new ReflectionMethod($controller, 'usesLoggedInBranchOnlyAttendance');

        $desktopRequest = Request::create('/api/attendance/check-in', 'POST', [
            'attendance_mode' => 'web_desktop',
            'web_view_width' => 1366,
            'web_view_height' => 768,
            'web_has_fine_pointer' => '1',
            'web_has_touch_input' => '0',
        ]);
        $touchRequest = Request::create('/api/attendance/check-in', 'POST', [
            'attendance_mode' => 'web_desktop',
            'web_view_width' => 1366,
            'web_view_height' => 768,
            'web_has_fine_pointer' => '1',
            'web_has_touch_input' => '1',
        ]);

        $this->assertTrue($method->invoke($controller, $desktopRequest));
        $this->assertFalse($method->invoke($controller, $touchRequest));
    }

    public function test_legacy_xls_workbooks_are_accepted(): void
    {
        $path = tempnam(sys_get_temp_dir(), 'attica_xls_');
        $this->assertNotFalse($path);

        $spreadsheet = new Spreadsheet();
        $spreadsheet->getActiveSheet()->fromArray([
            ['Employee ID', 'Amount'],
            ['AGPL001', 1250],
        ]);

        try {
            (new Xls($spreadsheet))->save($path);
            $rows = SpreadsheetImportGuard::rows($path);

            $this->assertSame('Employee ID', $rows[0][0]);
            $this->assertSame('AGPL001', $rows[1][0]);
            $this->assertEquals(1250, $rows[1][1]);
        } finally {
            $spreadsheet->disconnectWorksheets();
            @unlink($path);
        }
    }
}
