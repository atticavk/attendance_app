<?php

namespace Tests\Unit;

use App\Models\Employee;
use App\Models\RecruitmentCandidate;
use App\Services\EmployeeIdGenerator;
use Illuminate\Support\Facades\Config;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Tests\TestCase;

class EmployeeIdGeneratorTest extends TestCase
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
        });

        Schema::create('recruitment_candidates', function ($table): void {
            $table->increments('id');
            $table->string('generated_emp_id', 7)->nullable()->unique();
            $table->timestamps();
        });
    }

    public function test_exists_checks_employee_and_recruitment_candidate_ids(): void
    {
        $employee = Employee::query()->create([
            'empId' => '1234567',
            'name' => 'Fixture Person 35',
        ]);

        RecruitmentCandidate::query()->create([
            'generated_emp_id' => '7654321',
        ]);

        $generator = $this->app->make(EmployeeIdGenerator::class);

        $this->assertTrue($generator->exists('1234567'));
        $this->assertTrue($generator->exists('7654321'));
        $this->assertFalse($generator->exists('1111111'));
        $this->assertFalse($generator->exists('1234567', $employee->id));
    }

    public function test_generate_returns_a_seven_digit_unused_id(): void
    {
        Employee::query()->create([
            'empId' => '1234567',
            'name' => 'Fixture Person 35',
        ]);

        RecruitmentCandidate::query()->create([
            'generated_emp_id' => '7654321',
        ]);

        $generator = $this->app->make(EmployeeIdGenerator::class);
        $generatedId = $generator->generate();

        $this->assertMatchesRegularExpression('/^\d{7}$/', $generatedId);
        $this->assertNotSame('1234567', $generatedId);
        $this->assertNotSame('7654321', $generatedId);
    }
}
