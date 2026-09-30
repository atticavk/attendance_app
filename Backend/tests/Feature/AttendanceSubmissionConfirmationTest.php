<?php

namespace Tests\Feature;

use App\Models\Attendance;
use App\Models\Employee;
use Illuminate\Support\Facades\Config;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Laravel\Sanctum\Sanctum;
use Tests\TestCase;

class AttendanceSubmissionConfirmationTest extends TestCase
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
            $table->string('empId')->unique();
            $table->string('name')->nullable();
            $table->string('status')->nullable();
            $table->string('shift_timing')->nullable();
            $table->boolean('is_night_shift')->default(false);
            $table->boolean('is_outsourced')->default(false);
        });

        Schema::create('attendance', function ($table): void {
            $table->increments('id');
            $table->string('empId');
            $table->string('check_in_branch_id')->nullable();
            $table->string('check_out_branch_id')->nullable();
            $table->string('photo_path')->nullable();
            $table->string('check_out_photo_path')->nullable();
            $table->decimal('latitude', 10, 7)->nullable();
            $table->decimal('longitude', 10, 7)->nullable();
            $table->decimal('check_out_latitude', 10, 7)->nullable();
            $table->decimal('check_out_longitude', 10, 7)->nullable();
            $table->date('check_in_date')->nullable();
            $table->time('check_in_time')->nullable();
            $table->date('check_out_date')->nullable();
            $table->time('check_out_time')->nullable();
            $table->uuid('check_in_submission_id')->nullable()->unique();
            $table->uuid('check_out_submission_id')->nullable()->unique();
            $table->string('attendance_status_override')->nullable();
            $table->timestamps();
        });
    }

    public function test_employee_can_confirm_only_the_exact_persisted_submission(): void
    {
        $employee = Employee::query()->create([
            'empId' => 'EMP001',
            'name' => 'Fixture Person 4',
            'status' => 'active',
            'shift_timing' => '10:00 AM - 7:00 PM',
        ]);
        $otherEmployee = Employee::query()->create([
            'empId' => 'EMP002',
            'name' => 'Fixture Person 5',
            'status' => 'active',
        ]);
        $submissionId = '123e4567-e89b-42d3-a456-426614174000';
        $otherSubmissionId = '123e4567-e89b-42d3-a456-426614174001';

        $attendance = Attendance::query()->create([
            'empId' => $employee->empId,
            'check_in_branch_id' => 'BR001',
            'check_in_date' => now()->toDateString(),
            'check_in_time' => '10:00:00',
            'check_in_submission_id' => $submissionId,
        ]);
        Attendance::query()->create([
            'empId' => $otherEmployee->empId,
            'check_in_branch_id' => 'BR002',
            'check_in_date' => now()->toDateString(),
            'check_in_time' => '10:05:00',
            'check_in_submission_id' => $otherSubmissionId,
        ]);

        Sanctum::actingAs($employee);

        $this->getJson('/api/attendance/latest?submission_id='.$submissionId.'&submission_type=check_in')
            ->assertOk()
            ->assertJsonPath('submissionConfirmed', true)
            ->assertJsonPath('attendance.id', $attendance->id)
            ->assertJsonPath('attendance.empId', 'EMP001');

        $this->getJson('/api/attendance/latest?submission_id='.$otherSubmissionId.'&submission_type=check_in')
            ->assertOk()
            ->assertJsonPath('submissionConfirmed', false)
            ->assertJsonPath('attendance', null);

        $this->getJson('/api/attendance/latest?submission_id='.$submissionId.'&submission_type=check_out')
            ->assertOk()
            ->assertJsonPath('submissionConfirmed', false)
            ->assertJsonPath('attendance', null);
    }
}
