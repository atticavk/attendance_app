<?php

namespace Tests\Feature;

use App\Models\Employee;
use App\Models\EmployeeAdvanceRequest;
use App\Models\EmployeeAdvanceTransaction;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Config;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Laravel\Sanctum\Sanctum;
use Tests\TestCase;

class SalarySummaryAdvanceWindowTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();

        Config::set('database.default', 'sqlite');
        Config::set('cache.default', 'array');
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
            $table->string('designation')->nullable();
            $table->decimal('salary', 12, 2)->nullable();
            $table->decimal('advance', 12, 2)->nullable();
            $table->decimal('pf', 12, 2)->nullable();
            $table->date('doj')->nullable();
        });

        Schema::create('employee_advance_transactions', function ($table): void {
            $table->increments('id');
            $table->integer('employee_id');
            $table->string('emp_id', 50);
            $table->date('advance_date');
            $table->decimal('amount', 12, 2);
            $table->string('source_type', 20)->default('manual');
            $table->string('source_file')->nullable();
            $table->unsignedInteger('source_row_no')->nullable();
            $table->string('row_hash', 64)->nullable()->unique();
            $table->text('remarks')->nullable();
            $table->timestamps();
        });

        Schema::create('employee_advance_requests', function ($table): void {
            $table->increments('id');
            $table->integer('employee_id');
            $table->string('emp_id', 50);
            $table->date('request_date');
            $table->decimal('amount', 12, 2);
            $table->text('request_note')->nullable();
            $table->string('status', 20);
            $table->text('admin_note')->nullable();
            $table->string('verified_by')->nullable();
            $table->timestamp('verified_at')->nullable();
            $table->string('rejected_by')->nullable();
            $table->timestamp('rejected_at')->nullable();
            $table->timestamps();
        });

        Schema::create('attendance', function ($table): void {
            $table->increments('id');
            $table->string('empId');
            $table->date('check_in_date')->nullable();
            $table->date('check_out_date')->nullable();
            $table->time('check_in_time')->nullable();
            $table->time('check_out_time')->nullable();
            $table->string('check_in_branch_id')->nullable();
            $table->string('check_out_branch_id')->nullable();
            $table->decimal('latitude', 10, 7)->nullable();
            $table->decimal('longitude', 10, 7)->nullable();
            $table->decimal('check_out_latitude', 10, 7)->nullable();
            $table->decimal('check_out_longitude', 10, 7)->nullable();
            $table->string('photo_path')->nullable();
            $table->string('check_out_photo_path')->nullable();
            $table->string('attendance_status_override')->nullable();
        });

        Schema::create('attendance_day_overrides', function ($table): void {
            $table->increments('id');
            $table->string('emp_id');
            $table->date('attendance_date');
            $table->string('final_status');
            $table->timestamps();
        });

        Schema::create('salary_calculation_settings', function ($table): void {
            $table->increments('id');
            $table->boolean('fixed_30_days')->default(false);
            $table->boolean('pf_enabled')->default(true);
            $table->integer('updated_by')->nullable();
            $table->timestamps();
        });

        Schema::create('employeeDetails', function ($table): void {
            $table->increments('id');
            $table->string('employeeId')->nullable();
            $table->string('uanNumber', 30)->default('');
            $table->decimal('salary', 12, 2)->nullable();
            $table->decimal('pfAmount', 12, 2)->nullable();
        });
    }

    protected function tearDown(): void
    {
        Carbon::setTestNow();

        parent::tearDown();
    }

    public function test_salary_summary_defaults_to_current_calendar_month(): void
    {
        Carbon::setTestNow(Carbon::parse('2026-05-05 09:00:00', 'Asia/Kolkata'));

        $employee = Employee::query()->create([
            'empId' => '1000110',
            'name' => 'Fixture Person 2',
            'salary' => 30000,
            'advance' => 0,
            'pf' => 0,
        ]);

        $this->createAdvance($employee, '2026-04-24', 1000);
        $this->createAdvance($employee, '2026-04-25', 2000);
        $this->createAdvance($employee, '2026-05-05', 3000);
        $this->createAdvance($employee, '2026-05-12', 4000);

        Sanctum::actingAs($employee);

        $response = $this->getJson('/api/salary/summary');

        $response->assertOk();
        $this->assertSame(0.0, (float) $response->json('summary.advance'));
        $this->assertSame('2026-05', $response->json('summary.month'));
        $this->assertSame('May 2026', $response->json('summary.monthLabel'));
        $this->assertSame(5, (int) $response->json('summary.daysElapsed'));
        $this->assertSame(31, (int) $response->json('summary.daysInMonth'));
    }

    public function test_salary_summary_can_show_previous_month_when_requested(): void
    {
        Carbon::setTestNow(Carbon::parse('2026-05-05 09:00:00', 'Asia/Kolkata'));

        $employee = Employee::query()->create([
            'empId' => '1000110',
            'name' => 'Fixture Person 2',
            'salary' => 30000,
            'advance' => 0,
            'pf' => 0,
        ]);

        $this->createAdvance($employee, '2026-04-25', 2000);
        $this->createAdvance($employee, '2026-05-05', 3000);
        $this->createAdvance($employee, '2026-05-20', 4000);
        $this->createAdvance($employee, '2026-05-25', 5000);

        Sanctum::actingAs($employee);

        $response = $this->getJson('/api/salary/summary?month=2026-04');

        $response->assertOk();
        $this->assertSame(5000.0, (float) $response->json('summary.advance'));
        $this->assertSame('2026-04', $response->json('summary.month'));
        $this->assertSame('April 2026', $response->json('summary.monthLabel'));
        $this->assertSame(30, (int) $response->json('summary.daysElapsed'));
        $this->assertSame(30, (int) $response->json('summary.daysInMonth'));
    }

    public function test_salary_summary_uses_employee_table_salary_over_imported_detail_salary(): void
    {
        Carbon::setTestNow(Carbon::parse('2026-05-05 09:00:00', 'Asia/Kolkata'));

        $employee = Employee::query()->create([
            'empId' => '1000110',
            'name' => 'Fixture Person 2',
            'salary' => 30000,
            'advance' => 0,
            'pf' => 0,
        ]);

        DB::table('employeeDetails')->insert([
            'employeeId' => '1000110',
            'uanNumber' => '',
            'salary' => 60000,
            'pfAmount' => 0,
        ]);

        $this->createAttendance($employee, '2026-04-01');

        Sanctum::actingAs($employee);

        $response = $this->getJson('/api/salary/summary?month=2026-04');

        $response->assertOk();
        $this->assertSame(30000.0, (float) $response->json('summary.salary'));
        $this->assertSame(1000.0, (float) $response->json('summary.salaryPerDay'));
    }

    public function test_salary_summary_does_not_carry_previous_payroll_month_advances_into_current_month_salary(): void
    {
        Carbon::setTestNow(Carbon::parse('2026-07-12 09:00:00', 'Asia/Kolkata'));

        $employee = Employee::query()->create([
            'empId' => '1000110',
            'name' => 'Fixture Person 2',
            'salary' => 30000,
            'advance' => 0,
            'pf' => 0,
        ]);

        $this->createAdvance($employee, '2026-05-23', 2000);
        $this->createAdvance($employee, '2026-06-11', 3000);
        $this->createAdvance($employee, '2026-06-12', 4000);

        Sanctum::actingAs($employee);

        $response = $this->getJson('/api/salary/summary?month=2026-06');

        $response->assertOk();
        $this->assertSame(0.0, (float) $response->json('summary.advance'));
        $this->assertSame('2026-06', $response->json('summary.month'));
        $this->assertSame('June 2026', $response->json('summary.monthLabel'));
    }

    public function test_salary_summary_counts_current_month_advances_once_the_13th_window_opens(): void
    {
        Carbon::setTestNow(Carbon::parse('2026-05-18 09:00:00', 'Asia/Kolkata'));

        $employee = Employee::query()->create([
            'empId' => '1000110',
            'name' => 'Fixture Person 2',
            'salary' => 30000,
            'advance' => 0,
            'pf' => 0,
        ]);

        $this->createAdvance($employee, '2026-05-12', 1000);
        $this->createAdvance($employee, '2026-05-13', 2000);
        $this->createAdvance($employee, '2026-05-18', 3000);
        $this->createAdvance($employee, '2026-06-12', 4000);

        Sanctum::actingAs($employee);

        $response = $this->getJson('/api/salary/summary');

        $response->assertOk();
        $this->assertSame(5000.0, (float) $response->json('summary.advance'));
        $this->assertSame('2026-05', $response->json('summary.month'));
    }

    public function test_july_advances_do_not_carry_into_august_salary(): void
    {
        Carbon::setTestNow(Carbon::parse('2026-08-19 09:00:00', 'Asia/Kolkata'));

        $employee = Employee::query()->create([
            'empId' => '1000110',
            'name' => 'Fixture Person 20',
            'salary' => 30000,
            'advance' => 0,
            'pf' => 0,
        ]);

        $this->createAdvance($employee, '2026-07-12', 1000);
        $this->createAdvance($employee, '2026-07-13', 2000);
        $this->createAdvance($employee, '2026-08-11', 3000);
        $this->createAdvance($employee, '2026-08-12', 4000);
        $this->createAdvance($employee, '2026-08-13', 5000);

        Sanctum::actingAs($employee);

        $julyResponse = $this->getJson('/api/salary/summary?month=2026-07');
        $augustResponse = $this->getJson('/api/salary/summary?month=2026-08');

        $julyResponse->assertOk();
        $augustResponse->assertOk();
        $this->assertSame(5000.0, (float) $julyResponse->json('summary.advance'));
        $this->assertSame(5000.0, (float) $augustResponse->json('summary.advance'));
    }

    public function test_advance_request_history_follows_the_salary_tab_selected_payroll_month(): void
    {
        Carbon::setTestNow(Carbon::parse('2026-08-19 09:00:00', 'Asia/Kolkata'));

        $employee = Employee::query()->create([
            'empId' => '1000110',
            'name' => 'Fixture Person 21',
            'salary' => 30000,
            'advance' => 0,
            'pf' => 0,
        ]);

        $julyRequest = $this->createAdvanceRequest($employee, '2026-07-25', 5000, EmployeeAdvanceRequest::STATUS_VERIFIED);
        $augustRequest = $this->createAdvanceRequest($employee, '2026-08-13', 3000, EmployeeAdvanceRequest::STATUS_PENDING);

        Sanctum::actingAs($employee);

        $this->getJson('/api/salary/summary?month=2026-08')->assertOk();
        $augustResponse = $this->getJson('/api/salary/advance-requests');

        $augustResponse->assertOk();
        $this->assertSame([$augustRequest->id], collect($augustResponse->json('advanceRequests'))->pluck('id')->all());

        $this->getJson('/api/salary/summary?month=2026-07')->assertOk();
        $julyResponse = $this->getJson('/api/salary/advance-requests');

        $julyResponse->assertOk();
        $this->assertSame([$julyRequest->id], collect($julyResponse->json('advanceRequests'))->pluck('id')->all());
    }

    public function test_verified_advance_request_from_an_earlier_month_blocks_a_new_request(): void
    {
        Carbon::setTestNow(Carbon::parse('2026-08-25 09:00:00', 'Asia/Kolkata'));

        $employee = Employee::query()->create([
            'empId' => '1000120',
            'name' => 'Fixture Person 22',
            'salary' => 30000,
            'advance' => 5000,
            'pf' => 0,
        ]);
        $existingRequest = $this->createAdvanceRequest(
            $employee,
            '2026-07-20',
            5000,
            EmployeeAdvanceRequest::STATUS_VERIFIED
        );

        Sanctum::actingAs($employee);

        $response = $this->postJson('/api/salary/advance-requests', [
            'amount' => 2500,
            'request_note' => 'Second request should be rejected.',
        ]);

        $response
            ->assertStatus(422)
            ->assertExactJson([
                'message' => 'Active advance request already exists.',
            ]);
        $this->assertDatabaseCount('employee_advance_requests', 1);
        $this->assertDatabaseHas('employee_advance_requests', [
            'id' => $existingRequest->id,
            'status' => EmployeeAdvanceRequest::STATUS_VERIFIED,
        ]);
    }

    public function test_rejected_advance_request_does_not_block_a_new_request(): void
    {
        Carbon::setTestNow(Carbon::parse('2026-08-25 09:00:00', 'Asia/Kolkata'));

        $employee = Employee::query()->create([
            'empId' => '1000121',
            'name' => 'Fixture Person 23',
            'salary' => 30000,
            'advance' => 0,
            'pf' => 0,
        ]);
        $this->createAdvanceRequest(
            $employee,
            '2026-07-20',
            5000,
            EmployeeAdvanceRequest::STATUS_REJECTED
        );

        Sanctum::actingAs($employee);

        $response = $this->postJson('/api/salary/advance-requests', [
            'amount' => 2500,
            'request_note' => 'Replacement request.',
        ]);

        $response
            ->assertCreated()
            ->assertJsonPath('advanceRequest.status', EmployeeAdvanceRequest::STATUS_PENDING);
        $this->assertDatabaseCount('employee_advance_requests', 2);
    }

    public function test_salary_summary_does_not_deduct_employee_advance_column(): void
    {
        Carbon::setTestNow(Carbon::parse('2026-06-12 09:00:00', 'Asia/Kolkata'));

        $employee = Employee::query()->create([
            'empId' => '1000110',
            'name' => 'Fixture Person 24',
            'salary' => 30000,
            'advance' => 9000,
            'pf' => 0,
        ]);

        Sanctum::actingAs($employee);

        $response = $this->getJson('/api/salary/summary?month=2026-05');

        $response->assertOk();
        $this->assertSame(0.0, (float) $response->json('summary.advance'));
    }

    public function test_salary_summary_counts_sundays_as_paid_days(): void
    {
        Carbon::setTestNow(Carbon::parse('2026-05-08 09:00:00', 'Asia/Kolkata'));

        $employee = Employee::query()->create([
            'empId' => '1000110',
            'name' => 'Fixture Person 2',
            'salary' => 30000,
            'advance' => 0,
            'pf' => 0,
        ]);

        $cursor = Carbon::create(2026, 4, 1, 0, 0, 0, 'Asia/Kolkata')->startOfMonth();
        $monthEnd = $cursor->copy()->endOfMonth();
        $absentDates = ['2026-04-03', '2026-04-18'];

        while ($cursor->lte($monthEnd)) {
            if (! $cursor->isSunday() && ! in_array($cursor->toDateString(), $absentDates, true)) {
                $this->createAttendance($employee, $cursor->toDateString());
            }

            $cursor->addDay();
        }

        Sanctum::actingAs($employee);

        $response = $this->getJson('/api/salary/summary?month=2026-04');

        $response->assertOk();
        $this->assertSame(4, (int) $response->json('summary.paidSundayDays'));
        $this->assertSame(2, (int) $response->json('summary.absentDays'));
        $this->assertSame(28.0, (float) $response->json('summary.payableDays'));
        $this->assertSame(1000.0, (float) $response->json('summary.salaryPerDay'));
        $this->assertSame(28000.0, (float) $response->json('summary.grossPayableSalary'));
    }

    public function test_salary_summary_can_use_fixed_thirty_day_proration(): void
    {
        Carbon::setTestNow(Carbon::parse('2026-03-10 09:00:00', 'Asia/Kolkata'));
        DB::table('salary_calculation_settings')->insert([
            'fixed_30_days' => true,
            'pf_enabled' => true,
        ]);
        $employee = Employee::query()->create([
            'empId' => '1000987',
            'name' => 'Fixture Person 25',
            'salary' => 30000,
            'advance' => 0,
            'pf' => 0,
        ]);
        $this->createAttendance($employee, '2026-02-02');
        Sanctum::actingAs($employee);

        $response = $this->getJson('/api/salary/summary?month=2026-02');

        $response->assertOk();
        $this->assertSame(30, (int) $response->json('summary.salaryDaysInMonth'));
        $this->assertSame(1000.0, (float) $response->json('summary.salaryPerDay'));
    }

    public function test_salary_summary_credits_a_sunday_as_full_day_when_marked_half_day(): void
    {
        Carbon::setTestNow(Carbon::parse('2026-05-08 09:00:00', 'Asia/Kolkata'));

        $employee = Employee::query()->create([
            'empId' => '1000988',
            'name' => 'Fixture Person 26',
            'salary' => 30000,
            'advance' => 0,
            'pf' => 0,
        ]);

        $this->createAttendance($employee, '2026-04-06');
        DB::table('attendance_day_overrides')->insert([
            'emp_id' => $employee->empId,
            'attendance_date' => '2026-04-05',
            'final_status' => 'half_day',
        ]);

        Sanctum::actingAs($employee);

        $response = $this->getJson('/api/salary/summary?month=2026-04');

        $response->assertOk();
        $this->assertSame(4, (int) $response->json('summary.paidSundayDays'));
        $this->assertSame(0, (int) $response->json('summary.halfDays'));
        $this->assertSame(5.0, (float) $response->json('summary.payableDays'));
        $this->assertSame(5000.0, (float) $response->json('summary.grossPayableSalary'));
    }

    public function test_salary_summary_does_not_credit_week_offs_before_joining_date(): void
    {
        Carbon::setTestNow(Carbon::parse('2026-06-10 09:00:00', 'Asia/Kolkata'));

        $employee = Employee::query()->create([
            'empId' => '1000989',
            'name' => 'Fixture Person 27',
            'salary' => 31000,
            'advance' => 0,
            'pf' => 0,
            'doj' => '2026-05-11',
        ]);
        $this->createAttendance($employee, '2026-05-12');

        Sanctum::actingAs($employee);

        $response = $this->getJson('/api/salary/summary?month=2026-05');

        $response->assertOk();
        $this->assertSame(3, (int) $response->json('summary.paidSundayDays'));
        $this->assertSame(4.0, (float) $response->json('summary.payableDays'));
        $this->assertSame(4000.0, (float) $response->json('summary.grossPayableSalary'));
    }

    public function test_salary_summary_is_zero_without_any_punch_or_regularized_day(): void
    {
        Carbon::setTestNow(Carbon::parse('2026-06-10 09:00:00', 'Asia/Kolkata'));

        $employee = Employee::query()->create([
            'empId' => '1000990',
            'name' => 'Fixture Person 28',
            'salary' => 30000,
            'advance' => 0,
            'pf' => 0,
        ]);

        Sanctum::actingAs($employee);

        $response = $this->getJson('/api/salary/summary?month=2026-05');

        $response->assertOk();
        $this->assertSame(0.0, (float) $response->json('summary.payableDays'));
        $this->assertSame(0.0, (float) $response->json('summary.grossPayableSalary'));
        $this->assertSame(0.0, (float) $response->json('summary.netPayableSalary'));
    }

    public function test_regularized_day_allows_salary_without_a_punch(): void
    {
        Carbon::setTestNow(Carbon::parse('2026-06-10 09:00:00', 'Asia/Kolkata'));

        $employee = Employee::query()->create([
            'empId' => '1000991',
            'name' => 'Fixture Person 29',
            'salary' => 30000,
            'advance' => 0,
            'pf' => 0,
        ]);
        DB::table('attendance_day_overrides')->insert([
            'emp_id' => $employee->empId,
            'attendance_date' => '2026-05-05',
            'final_status' => 'full_day',
        ]);

        Sanctum::actingAs($employee);

        $response = $this->getJson('/api/salary/summary?month=2026-05');

        $response->assertOk();
        $this->assertSame(1, (int) $response->json('summary.regularizedDays'));
        $this->assertGreaterThan(0, (float) $response->json('summary.grossPayableSalary'));
    }

    public function test_regularized_absent_day_is_included_in_payable_days(): void
    {
        Carbon::setTestNow(Carbon::parse('2026-06-10 09:00:00', 'Asia/Kolkata'));

        $employee = Employee::query()->create([
            'empId' => '1000992',
            'name' => 'Fixture Person 30',
            'salary' => 31000,
            'advance' => 0,
            'pf' => 0,
            'doj' => '2026-05-05',
        ]);
        DB::table('attendance_day_overrides')->insert([
            'emp_id' => $employee->empId,
            'attendance_date' => '2026-05-06',
            'final_status' => 'absent',
        ]);

        Sanctum::actingAs($employee);

        $response = $this->getJson('/api/salary/summary?month=2026-05');

        $response->assertOk();
        $this->assertSame(1, (int) $response->json('summary.regularizedDays'));
        $this->assertSame(5.0, (float) $response->json('summary.payableDays'));
        $this->assertSame(5000.0, (float) $response->json('summary.grossPayableSalary'));
    }

    public function test_regularized_days_before_first_physical_punch_are_payable(): void
    {
        Carbon::setTestNow(Carbon::parse('2026-06-10 09:00:00', 'Asia/Kolkata'));

        $employee = Employee::query()->create([
            'empId' => '1000993',
            'name' => 'Fixture Person 31',
            'salary' => 31000,
            'advance' => 0,
            'pf' => 0,
        ]);
        DB::table('attendance_day_overrides')->insert([
            'emp_id' => $employee->empId,
            'attendance_date' => '2026-05-20',
            'final_status' => 'full_day',
        ]);
        $this->createAttendance($employee, '2026-05-30');

        Sanctum::actingAs($employee);

        $response = $this->getJson('/api/salary/summary?month=2026-05');

        $response->assertOk();
        $this->assertSame(1, (int) $response->json('summary.regularizedDays'));
        $this->assertSame(4.0, (float) $response->json('summary.payableDays'));
        $this->assertSame(4000.0, (float) $response->json('summary.grossPayableSalary'));
    }

    public function test_salary_summary_for_current_month_counts_only_passed_sundays(): void
    {
        Carbon::setTestNow(Carbon::parse('2026-05-08 09:00:00', 'Asia/Kolkata'));

        $employee = Employee::query()->create([
            'empId' => '1000110',
            'name' => 'Fixture Person 2',
            'salary' => 30000,
            'advance' => 0,
            'pf' => 0,
        ]);

        Sanctum::actingAs($employee);

        $response = $this->getJson('/api/salary/summary');

        $response->assertOk();
        $this->assertSame(1, (int) $response->json('summary.paidSundayDays'));
    }

    public function test_salary_summary_does_not_count_current_sunday_until_it_has_passed(): void
    {
        Carbon::setTestNow(Carbon::parse('2026-05-10 09:00:00', 'Asia/Kolkata'));

        $employee = Employee::query()->create([
            'empId' => '1000110',
            'name' => 'Fixture Person 2',
            'salary' => 30000,
            'advance' => 0,
            'pf' => 0,
        ]);

        Sanctum::actingAs($employee);

        $response = $this->getJson('/api/salary/summary');

        $response->assertOk();
        $this->assertSame(1, (int) $response->json('summary.paidSundayDays'));
    }

    public function test_salary_summary_progress_uses_actual_calendar_month_length(): void
    {
        Carbon::setTestNow(Carbon::parse('2026-05-08 09:00:00', 'Asia/Kolkata'));

        $employee = Employee::query()->create([
            'empId' => '1000110',
            'name' => 'Fixture Person 2',
            'salary' => 30000,
            'advance' => 0,
            'pf' => 0,
        ]);

        Sanctum::actingAs($employee);

        $response = $this->getJson('/api/salary/summary?month=2026-02');

        $response->assertOk();
        $this->assertSame('2026-02', $response->json('summary.month'));
        $this->assertSame(28, (int) $response->json('summary.daysElapsed'));
        $this->assertSame(28, (int) $response->json('summary.daysInMonth'));
        $this->assertSame(1071.43, (float) $response->json('summary.salaryPerDay'));
    }

    public function test_salary_summary_deducts_pf_for_allowlisted_employee_in_may_2026(): void
    {
        Carbon::setTestNow(Carbon::parse('2026-06-10 09:00:00', 'Asia/Kolkata'));

        $employee = $this->createEmployeeWithUan('1000110', '900000000001', 1800);

        Sanctum::actingAs($employee);

        $response = $this->getJson('/api/salary/summary?month=2026-05');

        $response->assertOk();
        $this->assertSame(1800.0, (float) $response->json('summary.pf'));
    }

    public function test_salary_summary_returns_pf_calculated_from_prorated_pf_rate_of_wages(): void
    {
        Carbon::setTestNow(Carbon::parse('2026-06-10 09:00:00', 'Asia/Kolkata'));

        $employee = $this->createEmployeeWithUan('1000110', '900000000001', 1800);
        $this->createAttendance($employee, '2026-05-05');

        Sanctum::actingAs($employee);

        $response = $this->getJson('/api/salary/summary?month=2026-05');

        $response->assertOk();
        $expectedPfRateOfWages = (12750 + 4550) / 31 * 5;
        $expectedPf = round($expectedPfRateOfWages * 0.12, 2);
        $this->assertSame($expectedPf, (float) $response->json('summary.pf'));
        $this->assertLessThan(1800, (float) $response->json('summary.pf'));
    }

    public function test_salary_summary_deducts_may_security_deposit_for_eligible_pf_designation(): void
    {
        Carbon::setTestNow(Carbon::parse('2026-06-10 09:00:00', 'Asia/Kolkata'));

        $employee = $this->createEmployeeWithUan('1000110', '900000000001', 1800, 'Branch Co Ordinator');

        Sanctum::actingAs($employee);

        $response = $this->getJson('/api/salary/summary?month=2026-05');

        $response->assertOk();
        $this->assertSame(5000.0, (float) $response->json('summary.securityDeposit'));
        $this->assertSame(
            (float) $response->json('summary.grossPayableSalary') - 1800 - 5000,
            (float) $response->json('summary.netPayableSalary')
        );
    }

    public function test_salary_summary_uses_allowlist_pf_when_eligible_employee_stored_pf_is_zero(): void
    {
        Carbon::setTestNow(Carbon::parse('2026-06-10 09:00:00', 'Asia/Kolkata'));

        $employee = $this->createEmployeeWithUan('1000114', '900000000001', 0);

        Sanctum::actingAs($employee);

        $response = $this->getJson('/api/salary/summary?month=2026-06');

        $response->assertOk();
        $this->assertSame(1800.0, (float) $response->json('summary.pf'));
        $this->assertSame(
            (float) $response->json('summary.grossPayableSalary') - 1800,
            (float) $response->json('summary.netPayableSalary')
        );
    }

    public function test_salary_summary_does_not_deduct_pf_for_unlisted_employee_from_may_2026_onward(): void
    {
        Carbon::setTestNow(Carbon::parse('2026-07-10 09:00:00', 'Asia/Kolkata'));

        $employee = $this->createEmployeeWithUan('8000013', '999999999999', 1800);

        Sanctum::actingAs($employee);

        $response = $this->getJson('/api/salary/summary?month=2026-06');

        $response->assertOk();
        $this->assertSame(0.0, (float) $response->json('summary.pf'));
        $this->assertSame(
            (float) $response->json('summary.grossPayableSalary'),
            (float) $response->json('summary.netPayableSalary')
        );
    }

    public function test_salary_summary_deducts_pf_for_allowlisted_employee_after_may_2026(): void
    {
        Carbon::setTestNow(Carbon::parse('2026-07-10 09:00:00', 'Asia/Kolkata'));

        $employee = $this->createEmployeeWithUan('1000112', '900000000001', 1800);

        Sanctum::actingAs($employee);

        $response = $this->getJson('/api/salary/summary?month=2026-06');

        $response->assertOk();
        $this->assertSame(1800.0, (float) $response->json('summary.pf'));
        $this->assertSame(
            (float) $response->json('summary.grossPayableSalary') - 1800,
            (float) $response->json('summary.netPayableSalary')
        );
    }

    public function test_salary_summary_does_not_deduct_pf_before_may_2026(): void
    {
        Carbon::setTestNow(Carbon::parse('2026-06-10 09:00:00', 'Asia/Kolkata'));

        $employee = $this->createEmployeeWithUan('1000113', '900000000001', 1800);

        Sanctum::actingAs($employee);

        $response = $this->getJson('/api/salary/summary?month=2026-04');

        $response->assertOk();
        $this->assertSame(0.0, (float) $response->json('summary.pf'));
    }

    public function test_salary_summary_sets_pf_to_zero_when_pf_calculation_is_disabled(): void
    {
        Carbon::setTestNow(Carbon::parse('2026-07-10 09:00:00', 'Asia/Kolkata'));
        DB::table('salary_calculation_settings')->insert([
            'fixed_30_days' => false,
            'pf_enabled' => false,
        ]);
        $employee = $this->createEmployeeWithUan('1000114', '900000000001', 1800);
        $this->createAttendance($employee, '2026-06-01');
        Sanctum::actingAs($employee);

        $response = $this->getJson('/api/salary/summary?month=2026-06');

        $response->assertOk();
        $this->assertSame(0.0, (float) $response->json('summary.pf'));
    }

    private function createAdvance(Employee $employee, string $date, float $amount): void
    {
        EmployeeAdvanceTransaction::query()->create([
            'employee_id' => $employee->id,
            'emp_id' => $employee->empId,
            'advance_date' => $date,
            'amount' => $amount,
            'source_type' => 'manual',
            'remarks' => 'Test advance entry',
        ]);
    }

    private function createAdvanceRequest(Employee $employee, string $date, float $amount, string $status): EmployeeAdvanceRequest
    {
        return EmployeeAdvanceRequest::query()->create([
            'employee_id' => $employee->id,
            'emp_id' => $employee->empId,
            'request_date' => $date,
            'amount' => $amount,
            'status' => $status,
            'verified_at' => $status === EmployeeAdvanceRequest::STATUS_VERIFIED ? $date.' 12:00:00' : null,
        ]);
    }

    private function createEmployeeWithUan(string $empId, string $uanNumber, float $pf, ?string $designation = null): Employee
    {
        $employee = Employee::query()->create([
            'empId' => $empId,
            'name' => 'Fixture Person 32',
            'designation' => $designation,
            'salary' => 30000,
            'advance' => 0,
            'pf' => $pf,
        ]);

        DB::table('employeeDetails')->insert([
            'employeeId' => $empId,
            'uanNumber' => $uanNumber,
            'salary' => 30000,
            'pfAmount' => $pf,
        ]);

        return $employee;
    }

    private function createAttendance(Employee $employee, string $date): void
    {
        DB::table('attendance')->insert([
            'empId' => $employee->empId,
            'check_in_date' => $date,
            'check_out_date' => $date,
            'check_in_time' => '10:00:00',
            'check_out_time' => '19:00:00',
            'check_in_branch_id' => 'BR001',
            'check_out_branch_id' => 'BR001',
            'attendance_status_override' => null,
        ]);
    }
}
