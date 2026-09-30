<?php

namespace Tests\Unit;

use App\Models\Attendance;
use App\Models\Employee;
use App\Models\EmployeeShiftHistory;
use App\Services\AttendanceClassificationService;
use Tests\TestCase;

class AttendanceClassificationServiceTest extends TestCase
{
    private AttendanceClassificationService $service;

    protected function setUp(): void
    {
        parent::setUp();

        $this->service = new AttendanceClassificationService();
    }

    public function test_punches_on_both_ten_minute_boundaries_are_full_day(): void
    {
        $employee = $this->employeeWithShift('9:00 AM - 6:00 PM');

        $this->assertSame('full_day', $this->status($employee, '08:50:00', '17:50:00'));
        $this->assertSame('full_day', $this->status($employee, '09:10:00', '18:10:00'));
    }

    public function test_duration_can_qualify_outside_the_punch_windows(): void
    {
        $employee = $this->employeeWithShift('9:00 AM - 6:00 PM');

        $this->assertSame('full_day', $this->status($employee, '09:20:00', '18:00:00'));
        $this->assertSame('half_day', $this->status($employee, '09:21:00', '18:00:00'));
    }

    public function test_eleven_hour_shift_requires_ten_hours_and_forty_minutes(): void
    {
        $employee = $this->employeeWithShift('8:00 AM - 7:00 PM');

        $this->assertSame('full_day', $this->status($employee, '08:20:00', '19:00:00'));
        $this->assertSame('half_day', $this->status($employee, '08:21:00', '19:00:00'));
    }

    public function test_completed_punches_outside_windows_and_below_duration_are_half_day(): void
    {
        $employee = $this->employeeWithShift('9:00 AM - 6:00 PM');

        $this->assertSame('half_day', $this->status($employee, '09:11:00', '17:49:00'));
    }

    public function test_missing_checkout_remains_single_punch(): void
    {
        $employee = $this->employeeWithShift('9:00 AM - 6:00 PM');
        $attendance = $this->attendance('09:00:00', null);

        $this->assertSame('single_punch', $this->service->calculatedStatus($attendance, $employee));
    }

    public function test_overnight_shift_uses_the_next_day_checkout(): void
    {
        $employee = $this->employeeWithShift('9:00 PM - 6:00 AM');
        $attendance = $this->attendance('21:10:00', '05:50:00', '2026-09-02');

        $this->assertSame('full_day', $this->service->calculatedStatus($attendance, $employee));
    }

    public function test_date_effective_shift_history_controls_historical_classification(): void
    {
        $employee = $this->employeeWithShift('9:00 AM - 6:00 PM');
        $employee->setRelation('shiftHistories', collect([
            new EmployeeShiftHistory([
                'shift_timing' => '10:00 AM - 7:00 PM',
                'effective_from' => '1900-01-01',
            ]),
            new EmployeeShiftHistory([
                'shift_timing' => '9:00 AM - 6:00 PM',
                'effective_from' => '2026-09-01',
            ]),
        ]));

        $oldAttendance = $this->attendance('10:10:00', '18:50:00', '2026-08-31', '2026-08-31');
        $newAttendance = $this->attendance('09:10:00', '17:50:00');

        $this->assertSame('full_day', $this->service->calculatedStatus($oldAttendance, $employee));
        $this->assertSame('full_day', $this->service->calculatedStatus($newAttendance, $employee));
    }

    public function test_imported_attendance_uses_the_same_shift_rule(): void
    {
        $employee = $this->employeeWithShift('9:00 AM - 6:00 PM');

        $this->assertSame('full_day', $this->service->calculatedImportedStatus(
            '8000156',
            '2026-09-01',
            '09:20:00',
            '18:00:00',
            31200,
            $employee
        ));
        $this->assertSame('half_day', $this->service->calculatedImportedStatus(
            '8000156',
            '2026-09-01',
            '09:21:00',
            '18:00:00',
            31140,
            $employee
        ));
    }

    public function test_imported_overnight_attendance_uses_next_day_checkout(): void
    {
        $employee = $this->employeeWithShift('9:00 PM - 6:00 AM');

        $this->assertSame('full_day', $this->service->calculatedImportedStatus(
            '8000156',
            '2026-09-01',
            '21:10:00',
            '05:50:00',
            null,
            $employee
        ));
    }

    public function test_missing_shift_timing_uses_the_existing_ten_to_seven_fallback(): void
    {
        $employee = $this->employeeWithShift('');

        $this->assertSame('full_day', $this->status($employee, '10:10:00', '18:50:00'));
    }

    private function status(Employee $employee, string $checkInTime, string $checkOutTime): string
    {
        return $this->service->calculatedStatus(
            $this->attendance($checkInTime, $checkOutTime),
            $employee
        );
    }

    private function attendance(
        string $checkInTime,
        ?string $checkOutTime,
        string $checkOutDate = '2026-09-01',
        string $checkInDate = '2026-09-01'
    ): Attendance {
        return new Attendance([
            'empId' => '8000156',
            'check_in_date' => $checkInDate,
            'check_in_time' => $checkInTime,
            'check_out_date' => $checkOutTime === null ? null : $checkOutDate,
            'check_out_time' => $checkOutTime,
        ]);
    }

    private function employeeWithShift(string $shiftTiming): Employee
    {
        return new Employee([
            'empId' => '8000156',
            'shift_timing' => $shiftTiming,
        ]);
    }
}
