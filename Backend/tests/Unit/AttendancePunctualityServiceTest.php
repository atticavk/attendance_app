<?php

namespace Tests\Unit;

use App\Models\Attendance;
use App\Models\Employee;
use App\Models\EmployeeShiftHistory;
use App\Services\AttendancePunctualityService;
use Illuminate\Support\Carbon;
use Tests\TestCase;

class AttendancePunctualityServiceTest extends TestCase
{
    public function test_app_attendance_within_ten_minute_grace_is_not_late_or_early_logout(): void
    {
        $service = new AttendancePunctualityService();
        $employee = $this->employeeWithShift('10:00 AM - 7:00 PM');
        $date = '2026-05-15';

        $result = $service->analyzeEmployee(
            $employee,
            [
                $date => new Attendance([
                    'check_in_date' => $date,
                    'check_in_time' => '10:10:00',
                    'check_out_date' => $date,
                    'check_out_time' => '18:50:00',
                ]),
            ],
            [],
            null,
            Carbon::parse($date),
            Carbon::parse($date)
        );

        $this->assertSame(0, $result['late_days_count']);
        $this->assertSame(0, $result['early_logout_days_count']);
        $this->assertSame([], $result['details']);
    }

    public function test_app_attendance_after_ten_minute_grace_is_late_and_early_logout(): void
    {
        $service = new AttendancePunctualityService();
        $employee = $this->employeeWithShift('10:00 AM - 7:00 PM');
        $date = '2026-05-15';

        $result = $service->analyzeEmployee(
            $employee,
            [
                $date => new Attendance([
                    'check_in_date' => $date,
                    'check_in_time' => '10:11:00',
                    'check_out_date' => $date,
                    'check_out_time' => '18:49:00',
                ]),
            ],
            [],
            null,
            Carbon::parse($date),
            Carbon::parse($date)
        );

        $this->assertSame(1, $result['late_days_count']);
        $this->assertSame(1, $result['early_logout_days_count']);
        $this->assertSame('1 min late', $result['details'][0]['late_label']);
        $this->assertSame('1 min early', $result['details'][0]['early_logout_label']);
    }

    public function test_imported_attendance_uses_same_ten_minute_grace(): void
    {
        $service = new AttendancePunctualityService();
        $employee = $this->employeeWithShift('10:00 AM - 7:00 PM');
        $date = '2026-05-15';

        $result = $service->analyzeEmployee(
            $employee,
            [],
            [
                $date => [
                    'first_login' => '10:10:00',
                    'last_logout' => '18:50:00',
                ],
            ],
            null,
            Carbon::parse($date),
            Carbon::parse($date)
        );

        $this->assertSame(0, $result['late_days_count']);
        $this->assertSame(0, $result['early_logout_days_count']);
        $this->assertSame([], $result['details']);
    }

    public function test_each_attendance_date_uses_the_shift_effective_on_that_date(): void
    {
        $service = new AttendancePunctualityService();
        $employee = $this->employeeWithShift('9:00 AM - 6:00 PM');
        $employee->setRelation('shiftHistories', collect([
            new EmployeeShiftHistory([
                'shift_timing' => '10:00 AM - 7:00 PM',
                'effective_from' => '1900-01-01',
            ]),
            new EmployeeShiftHistory([
                'shift_timing' => '9:00 AM - 6:00 PM',
                'effective_from' => '2026-05-12',
            ]),
        ]));

        $result = $service->analyzeEmployee(
            $employee,
            [
                '2026-05-09' => new Attendance([
                    'check_in_time' => '09:30:00',
                    'check_out_time' => '19:00:00',
                ]),
                '2026-05-13' => new Attendance([
                    'check_in_time' => '09:30:00',
                    'check_out_time' => '18:00:00',
                ]),
            ],
            [],
            null,
            Carbon::parse('2026-05-09'),
            Carbon::parse('2026-05-13')
        );

        $this->assertSame(1, $result['late_days_count']);
        $this->assertSame('09:00 AM', $result['details'][0]['shift_start']);
        $this->assertSame('Varies by attendance date', $result['schedule_label']);
        $this->assertSame(['10:00 AM - 07:00 PM', '09:00 AM - 06:00 PM'], $result['schedule_labels']);
    }

    public function test_timing_totals_and_averages_use_each_dates_effective_shift(): void
    {
        $service = new AttendancePunctualityService();
        $employee = $this->employeeWithShift('9:00 AM - 6:00 PM');
        $employee->setRelation('shiftHistories', collect([
            new EmployeeShiftHistory([
                'shift_timing' => '10:00 AM - 7:00 PM',
                'effective_from' => '1900-01-01',
            ]),
            new EmployeeShiftHistory([
                'shift_timing' => '9:00 AM - 6:00 PM',
                'effective_from' => '2026-05-12',
            ]),
        ]));

        $result = $service->analyzeEmployee(
            $employee,
            [
                '2026-05-09' => new Attendance([
                    'check_in_date' => '2026-05-09',
                    'check_in_time' => '10:30:00',
                    'check_out_date' => '2026-05-09',
                    'check_out_time' => '18:30:00',
                ]),
                '2026-05-13' => new Attendance([
                    'check_in_date' => '2026-05-13',
                    'check_in_time' => '09:00:00',
                    'check_out_date' => '2026-05-13',
                    'check_out_time' => '18:00:00',
                ]),
            ],
            [],
            null,
            Carbon::parse('2026-05-09'),
            Carbon::parse('2026-05-13')
        );

        $this->assertSame(18 * 3600, $result['expected_seconds']);
        $this->assertSame(17 * 3600, $result['worked_seconds']);
        $this->assertSame(94.4, $result['hours_completion_percent']);
        $this->assertSame(20.0, $result['average_late_minutes']);
        $this->assertSame(20.0, $result['average_early_logout_minutes']);
    }

    public function test_imported_overnight_timing_uses_logged_duration_and_nine_hour_schedule(): void
    {
        $service = new AttendancePunctualityService();
        $employee = $this->employeeWithShift('9:00 PM - 6:00 AM');
        $date = '2026-05-15';

        $result = $service->analyzeEmployee(
            $employee,
            [],
            [
                $date => [
                    'first_login' => '21:00:00',
                    'last_logout' => '06:00:00',
                    'logged_seconds' => 9 * 3600,
                ],
            ],
            null,
            Carbon::parse($date),
            Carbon::parse($date)
        );

        $this->assertSame(9 * 3600, $result['expected_seconds']);
        $this->assertSame(9 * 3600, $result['worked_seconds']);
        $this->assertSame(100.0, $result['hours_completion_percent']);
        $this->assertSame(0, $result['late_days_count']);
        $this->assertSame(0, $result['early_logout_days_count']);
    }

    private function employeeWithShift(string $shiftTiming): Employee
    {
        return new Employee([
            'empId' => '1234567',
            'name' => 'Fixture Person 4',
            'shift_timing' => $shiftTiming,
        ]);
    }
}
