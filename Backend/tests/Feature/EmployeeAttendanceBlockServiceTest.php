<?php

namespace Tests\Feature;

use App\Models\Employee;
use App\Services\EmployeeAttendanceBlockService;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Config;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Tests\TestCase;

class EmployeeAttendanceBlockServiceTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();

        Config::set('database.default', 'sqlite');
        Config::set('database.connections.sqlite', [
            'driver' => 'sqlite',
            'database' => ':memory:',
            'prefix' => '',
            'foreign_key_constraints' => true,
        ]);

        DB::purge('sqlite');
        DB::setDefaultConnection('sqlite');
        DB::reconnect('sqlite');

        Schema::create('employee', function ($table): void {
            $table->increments('id');
            $table->string('empId')->nullable()->unique();
            $table->string('name')->nullable();
            $table->string('status')->nullable();
            $table->date('doj')->nullable();
            $table->date('attendance_blocked_on')->nullable();
            $table->date('attendance_unblocked_on')->nullable();
        });

        Schema::create('attendance', function ($table): void {
            $table->increments('id');
            $table->string('empId')->nullable();
            $table->date('check_in_date')->nullable();
            $table->time('check_in_time')->nullable();
            $table->date('check_out_date')->nullable();
            $table->time('check_out_time')->nullable();
            $table->string('attendance_status_override')->nullable();
            $table->timestamps();
        });

        Schema::create('leave_requests', function ($table): void {
            $table->increments('id');
            $table->unsignedInteger('employee_id');
            $table->string('emp_id');
            $table->date('leave_date');
            $table->string('status')->default('pending');
            $table->timestamps();
        });

        Schema::create('site_visit_requests', function ($table): void {
            $table->increments('id');
            $table->unsignedInteger('employee_id');
            $table->string('emp_id');
            $table->date('visit_date');
            $table->string('status')->default('pending');
            $table->timestamps();
        });
    }

    public function test_sync_eligible_employees_treats_null_and_blank_status_as_active(): void
    {
        $nullStatusEmployee = $this->employeeWithOldAttendance('EMP001', null);
        $blankStatusEmployee = $this->employeeWithOldAttendance('EMP002', '');

        $blockedCount = (new EmployeeAttendanceBlockService())
            ->syncEligibleEmployees(Carbon::parse('2026-07-14', 'Asia/Kolkata'));

        $this->assertSame(2, $blockedCount);

        $this->assertSame('Blocked', $nullStatusEmployee->fresh()->status);
        $this->assertSame('2026-07-14', $nullStatusEmployee->fresh()->attendance_blocked_on);
        $this->assertSame('Blocked', $blankStatusEmployee->fresh()->status);
        $this->assertSame('2026-07-14', $blankStatusEmployee->fresh()->attendance_blocked_on);
    }

    public function test_sync_employee_treats_blank_status_as_active(): void
    {
        $employee = $this->employeeWithOldAttendance('EMP003', '');

        $blocked = (new EmployeeAttendanceBlockService())
            ->syncEmployee($employee, Carbon::parse('2026-07-14', 'Asia/Kolkata'));

        $this->assertTrue($blocked);
        $this->assertSame('Blocked', $employee->fresh()->status);
        $this->assertSame('2026-07-14', $employee->fresh()->attendance_blocked_on);
    }

    public function test_inactive_employee_is_not_treated_as_active_for_blocking(): void
    {
        $employee = $this->employeeWithOldAttendance('EMP004', 'Inactive');

        $blocked = (new EmployeeAttendanceBlockService())
            ->syncEmployee($employee, Carbon::parse('2026-07-14', 'Asia/Kolkata'));

        $this->assertFalse($blocked);
        $this->assertSame('Inactive', $employee->fresh()->status);
        $this->assertNull($employee->fresh()->attendance_blocked_on);
    }

    public function test_pending_work_visit_submission_prevents_blocking(): void
    {
        $employee = $this->employeeWithOldAttendance('EMP005', 'Active');
        DB::table('site_visit_requests')->insert([
            'employee_id' => $employee->id,
            'emp_id' => $employee->empId,
            'visit_date' => '2026-07-13',
            'status' => 'pending',
            'created_at' => now(),
            'updated_at' => now(),
        ]);

        $blocked = (new EmployeeAttendanceBlockService())
            ->syncEmployee($employee, Carbon::parse('2026-07-14', 'Asia/Kolkata'));

        $this->assertFalse($blocked);
        $this->assertSame('Active', $employee->fresh()->status);
    }

    public function test_submitted_leave_prevents_blocking_regardless_of_review_status(): void
    {
        $employee = $this->employeeWithOldAttendance('EMP006', 'Active');
        DB::table('leave_requests')->insert([
            'employee_id' => $employee->id,
            'emp_id' => $employee->empId,
            'leave_date' => '2026-07-11',
            'status' => 'rejected',
            'created_at' => now(),
            'updated_at' => now(),
        ]);

        $blocked = (new EmployeeAttendanceBlockService())
            ->syncEmployee($employee, Carbon::parse('2026-07-14', 'Asia/Kolkata'));

        $this->assertFalse($blocked);
        $this->assertSame('Active', $employee->fresh()->status);
    }

    public function test_recent_joiner_is_not_blocked_during_first_seven_calendar_days(): void
    {
        $employee = $this->employeeWithOldAttendance('EMP007', 'Active');
        $employee->update(['doj' => '2026-07-08']);
        $service = new EmployeeAttendanceBlockService();
        $today = Carbon::parse('2026-07-14', 'Asia/Kolkata');

        $blockedCount = $service->syncEligibleEmployees($today);

        $this->assertSame(0, $blockedCount);
        $this->assertFalse($service->syncEmployee($employee->fresh(), $today));
        $this->assertFalse($service->isBlocked($employee->fresh(), $today));
        $this->assertSame(0, $service->consecutiveAbsentDays($employee->fresh(), $today));
        $this->assertSame('Active', $employee->fresh()->status);
        $this->assertNull($employee->fresh()->attendance_blocked_on);
    }

    public function test_grace_period_absences_do_not_trigger_blocking_until_three_working_days_after_grace(): void
    {
        $employee = $this->employeeWithOldAttendance('EMP008', 'Active');
        $employee->update(['doj' => '2026-07-01']);
        $service = new EmployeeAttendanceBlockService();

        $this->assertFalse($service->syncEmployee(
            $employee->fresh(),
            Carbon::parse('2026-07-08', 'Asia/Kolkata')
        ));
        $this->assertSame('Active', $employee->fresh()->status);

        $this->assertTrue($service->syncEmployee(
            $employee->fresh(),
            Carbon::parse('2026-07-14', 'Asia/Kolkata')
        ));
        $this->assertSame('Blocked', $employee->fresh()->status);
        $this->assertSame('2026-07-14', $employee->fresh()->attendance_blocked_on);
    }

    private function employeeWithOldAttendance(string $empId, ?string $status): Employee
    {
        $employee = Employee::query()->create([
            'empId' => $empId,
            'name' => 'Fixture Person 4',
            'status' => $status,
        ]);

        DB::table('attendance')->insert([
            'empId' => $empId,
            'check_in_date' => '2026-07-09',
            'check_in_time' => '09:30:00',
            'created_at' => now(),
            'updated_at' => now(),
        ]);

        return $employee;
    }
}
