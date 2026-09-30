<?php

namespace Tests\Feature;

use App\Http\Controllers\Admin\EmployeeController;
use App\Services\EmployeeIdGenerator;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Config;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Mockery;
use Tests\TestCase;

class EmployeeDirectoryDatabasePaginationTest extends TestCase
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
            $table->string('empId');
            $table->string('name');
            $table->string('designation')->nullable();
            $table->string('photo')->nullable();
            $table->string('status')->nullable();
            $table->string('inactive_reason')->nullable();
            $table->date('last_working_date')->nullable();
            $table->string('last_login_branch_id')->nullable();
            $table->date('doj')->nullable();
            $table->string('shift_timing')->nullable();
            $table->boolean('is_outsourced')->default(false);
        });
        Schema::create('attendance', function ($table): void {
            $table->increments('id');
            $table->string('empId');
            $table->string('check_in_branch_id')->nullable();
            $table->string('check_out_branch_id')->nullable();
            $table->date('check_in_date')->nullable();
            $table->time('check_in_time')->nullable();
            $table->date('check_out_date')->nullable();
            $table->time('check_out_time')->nullable();
        });
        Schema::create('wp_branches_database', function ($table): void {
            $table->increments('id');
            $table->string('branchId')->unique();
            $table->string('branchName');
            $table->string('city')->nullable();
            $table->string('state')->nullable();
            $table->boolean('status')->default(true);
        });
        Schema::create('outsource_locations', function ($table): void {
            $table->increments('id');
            $table->string('location_code')->unique();
            $table->string('name');
            $table->string('city')->nullable();
            $table->string('state')->nullable();
        });
        Schema::create('recruitment_candidates', function ($table): void {
            $table->increments('id');
            $table->string('status')->nullable();
            $table->string('generated_emp_id')->nullable();
            $table->json('onboarding_payload')->nullable();
            $table->timestamp('onboarding_completed_at')->nullable();
            $table->timestamps();
        });
    }

    public function test_employee_directory_resolves_branches_before_paginating_the_collection(): void
    {
        DB::table('wp_branches_database')->insert([
            'branchId' => 'AGPL001',
            'branchName' => 'Bengaluru Main',
            'city' => 'Bengaluru',
            'state' => 'Karnataka',
            'status' => true,
        ]);

        $employees = [];
        for ($index = 1; $index <= 120; $index++) {
            $employees[] = [
                'empId' => sprintf('100%04d', $index),
                'name' => 'Fixture Person 6'.$index,
                'designation' => 'Executive',
                'status' => 'Active',
                'last_login_branch_id' => 'AGPL001',
                'is_outsourced' => false,
            ];
        }
        DB::table('employee')->insert($employees);

        $idGenerator = Mockery::mock(EmployeeIdGenerator::class);
        $idGenerator->shouldReceive('suggestions')->once()->with(2)->andReturn(['1000121', '1000122']);
        $controller = new EmployeeController($idGenerator);
        $view = $controller->index(Request::create('/admin/employee/index', 'GET', ['tab' => 'active']));
        $paginator = $view->getData()['paginator'];

        $this->assertSame(120, $paginator->total());
        $this->assertCount(50, $paginator->items());
        $this->assertSame('Bengaluru Main', $paginator->items()[0]->last_login_branch_name);
    }

    public function test_employee_directory_resolves_branch_from_trimmed_checkout_attendance(): void
    {
        DB::table('wp_branches_database')->insert([
            'branchId' => 'AGPL009',
            'branchName' => 'Jayanagar',
            'city' => 'Bengaluru',
            'state' => 'Karnataka',
            'status' => true,
        ]);
        DB::table('employee')->insert([
            'empId' => 'EMP009',
            'name' => 'Fixture Person 7',
            'designation' => 'Executive',
            'status' => 'Active',
            'last_login_branch_id' => null,
            'is_outsourced' => false,
        ]);
        DB::table('attendance')->insert([
            'empId' => 'EMP009',
            'check_in_branch_id' => null,
            'check_out_branch_id' => ' agpl009 ',
            'check_in_date' => '2026-09-15',
            'check_in_time' => '09:30:00',
            'check_out_date' => '2026-09-15',
            'check_out_time' => '18:30:00',
        ]);

        $idGenerator = Mockery::mock(EmployeeIdGenerator::class);
        $idGenerator->shouldReceive('suggestions')->once()->with(2)->andReturn(['EMP010', 'EMP011']);
        $controller = new EmployeeController($idGenerator);
        $view = $controller->index(Request::create('/admin/employee/index', 'GET', ['tab' => 'active']));
        $employee = $view->getData()['employees']->first();

        $this->assertSame('AGPL009', $employee->last_login_branch_id);
        $this->assertSame('Jayanagar', $employee->last_login_branch_name);
        $this->assertSame('Bengaluru', $employee->last_login_branch_city);
        $this->assertSame('Karnataka', $employee->last_login_branch_state);
    }

    public function test_employee_directory_shows_recorded_branch_id_without_master_data(): void
    {
        DB::table('employee')->insert([
            'empId' => 'EMP010',
            'name' => 'Fixture Person 8',
            'designation' => 'Executive',
            'status' => 'Active',
            'last_login_branch_id' => null,
            'is_outsourced' => false,
        ]);
        DB::table('attendance')->insert([
            'empId' => 'EMP010',
            'check_in_branch_id' => 'LEGACY010',
            'check_in_date' => '2026-09-15',
            'check_in_time' => '09:30:00',
        ]);

        $idGenerator = Mockery::mock(EmployeeIdGenerator::class);
        $idGenerator->shouldReceive('suggestions')->once()->with(2)->andReturn(['EMP011', 'EMP012']);
        $controller = new EmployeeController($idGenerator);
        $view = $controller->index(Request::create('/admin/employee/index', 'GET', ['tab' => 'active']));
        $employee = $view->getData()['employees']->first();

        $this->assertSame('LEGACY010', $employee->last_login_branch_id);
        $this->assertSame('LEGACY010', $employee->last_login_branch_name);
    }
}
