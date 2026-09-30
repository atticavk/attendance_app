<?php

namespace Tests\Feature;

use App\Models\Employee;
use App\Models\RecruitmentCandidate;
use Illuminate\Support\Facades\Config;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Tests\TestCase;

class EmployeeStoreTest extends TestCase
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
            $table->string('contact')->nullable();
            $table->string('mailId')->nullable();
            $table->text('address')->nullable();
            $table->string('designation')->nullable();
            $table->decimal('salary', 12, 2)->nullable();
            $table->date('doj')->nullable();
            $table->string('shift_timing')->nullable();
            $table->boolean('is_outsourced')->default(false);
            $table->decimal('advance', 12, 2)->nullable();
            $table->timestamps();
        });

        Schema::create('recruitment_candidates', function ($table): void {
            $table->increments('id');
            $table->string('generated_emp_id', 255)->nullable()->unique();
            $table->timestamps();
        });

        Schema::create('outsource_employee_locations', function ($table): void {
            $table->integer('employee_id');
            $table->integer('outsource_location_id');
        });

        $this->withoutMiddleware();
    }

    public function test_store_uses_manually_submitted_employee_id(): void
    {
        $response = $this->post(route('admin-employee-store'), [
            'empId' => 'MANUAL123',
            'name' => 'Fixture Person 12',
            'designation' => 'Developer',
            'salary' => '30000',
        ]);

        $response->assertRedirect(route('admin-employee-index'));

        $employee = Employee::query()->first();

        $this->assertNotNull($employee);
        $this->assertSame('MANUAL123', $employee->empId);
    }

    public function test_store_generates_employee_id_when_not_submitted(): void
    {
        RecruitmentCandidate::query()->create([
            'generated_emp_id' => '1234567',
        ]);

        $response = $this->post(route('admin-employee-store'), [
            'empId' => '',
            'name' => 'Fixture Person 13',
            'designation' => 'Developer',
            'salary' => '30000',
        ]);

        $response->assertRedirect(route('admin-employee-index'));

        $employee = Employee::query()->first();

        $this->assertNotNull($employee);
        $this->assertMatchesRegularExpression('/^\d{7}$/', $employee->empId);
        $this->assertNotSame('1234567', $employee->empId);
    }
}
