<?php

namespace Tests\Feature;

use App\Models\Employee;
use Illuminate\Support\Facades\Config;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Laravel\Sanctum\Sanctum;
use Tests\TestCase;

class EmployeeInactiveAccessTest extends TestCase
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
            $table->boolean('is_outsourced')->default(false);
            $table->boolean('is_night_shift')->default(false);
            $table->date('attendance_blocked_on')->nullable();
            $table->date('attendance_unblocked_on')->nullable();
        });
    }

    public function test_inactive_employee_cannot_login(): void
    {
        Employee::query()->create([
            'empId' => 'EMP001',
            'name' => 'Fixture Person 9',
            'status' => 'Inactive',
        ]);

        $response = $this->postJson('/api/employee/login', [
            'branchId' => 'BR001',
            'empId' => 'EMP001',
            'password' => 'Strong-Test-Password-123!',
        ]);

        $response
            ->assertUnprocessable()
            ->assertJsonValidationErrors('empId');
    }

    public function test_inactive_employee_with_existing_session_cannot_mark_attendance(): void
    {
        $employee = Employee::query()->create([
            'empId' => 'EMP002',
            'name' => 'Fixture Person 9',
            'status' => 'inactive',
        ]);

        Sanctum::actingAs($employee);

        $response = $this->postJson('/api/attendance/check-in', []);

        $response
            ->assertStatus(403)
            ->assertJsonPath('message', 'This employee account is inactive. Attendance is not allowed. Please contact HR.');
    }
}
