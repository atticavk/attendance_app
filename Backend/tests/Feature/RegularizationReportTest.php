<?php

namespace Tests\Feature;

use App\Http\Controllers\Admin\AttendanceManagementController;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Config;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Tests\TestCase;

class RegularizationReportTest extends TestCase
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

        Schema::create('admins', function ($table): void {
            $table->increments('id');
            $table->string('name')->nullable();
            $table->string('email');
            $table->timestamps();
        });
        Schema::create('employee', function ($table): void {
            $table->increments('id');
            $table->string('empId')->unique();
            $table->string('name')->nullable();
            $table->string('designation')->nullable();
            $table->string('assigned_branch_id')->nullable();
        });
        Schema::create('attendance', function ($table): void {
            $table->increments('id');
            $table->string('empId');
            $table->date('check_in_date');
            $table->string('check_in_branch_id')->nullable();
            $table->string('check_out_branch_id')->nullable();
            $table->string('attendance_status_override')->nullable();
            $table->string('attendance_status_override_by')->nullable();
            $table->timestamps();
        });
        Schema::create('wp_branches_database', function ($table): void {
            $table->increments('id');
            $table->string('branchId')->unique();
            $table->string('branchName');
            $table->string('state')->nullable();
            $table->string('city')->nullable();
            $table->boolean('status')->default(true);
        });
        Schema::create('admin_notifications', function ($table): void {
            $table->increments('id');
            $table->string('title');
            $table->text('body');
            $table->unsignedInteger('sent_by')->nullable();
            $table->timestamp('sent_at')->nullable();
            $table->timestamps();
        });
        Schema::create('employee_notification_deliveries', function ($table): void {
            $table->increments('id');
            $table->unsignedInteger('admin_notification_id');
            $table->unsignedInteger('employee_id');
            $table->timestamps();
        });
        Schema::create('site_visit_requests', function ($table): void {
            $table->increments('id');
            $table->unsignedInteger('employee_id');
            $table->string('emp_id');
            $table->date('visit_date');
            $table->string('status');
            $table->string('reviewed_by')->nullable();
            $table->timestamp('reviewed_at')->nullable();
            $table->unsignedInteger('attendance_id')->nullable();
            $table->timestamps();
        });
        Schema::create('ho_attendance_import_overrides', function ($table): void {
            $table->increments('id');
            $table->string('emp_id');
            $table->date('attendance_date');
            $table->string('final_status');
            $table->string('updated_by')->default('');
            $table->timestamps();
        });
        Schema::create('attendance_day_overrides', function ($table): void {
            $table->increments('id');
            $table->string('emp_id');
            $table->date('attendance_date');
            $table->string('final_status');
            $table->string('updated_by')->default('');
            $table->timestamps();
        });
    }

    public function test_report_filters_month_deduplicates_days_and_ranks_highest_count_first(): void
    {
        DB::table('admins')->insert([
            'id' => 7,
            'name' => 'Fixture Person 14',
            'email' => 'md@example.test',
        ]);
        DB::table('employee')->insert([
            ['empId' => 'E001', 'name' => 'Fixture Person 15', 'designation' => 'CSR', 'assigned_branch_id' => 'BR001'],
            ['empId' => 'E002', 'name' => 'Fixture Person 16', 'designation' => 'Telecaller', 'assigned_branch_id' => 'AGPL000'],
        ]);
        DB::table('wp_branches_database')->insert([
            ['branchId' => 'AGPL000', 'branchName' => 'Head Office', 'state' => 'Karnataka', 'city' => 'Bengaluru'],
            ['branchId' => 'BR001', 'branchName' => 'Mysuru', 'state' => 'Karnataka', 'city' => 'Mysuru'],
        ]);
        DB::table('attendance')->insert([
            [
                'empId' => 'E001',
                'check_in_date' => '2026-08-05',
                'check_in_branch_id' => 'BR001',
                'check_out_branch_id' => 'BR001',
                'attendance_status_override' => 'full_day',
                'attendance_status_override_by' => 'Reviewer One',
            ],
            [
                'empId' => 'E002',
                'check_in_date' => '2026-09-01',
                'check_in_branch_id' => 'AGPL000',
                'check_out_branch_id' => 'AGPL000',
                'attendance_status_override' => 'full_day',
                'attendance_status_override_by' => 'September Reviewer',
            ],
        ]);
        DB::table('ho_attendance_import_overrides')->insert([
            'emp_id' => 'E002',
            'attendance_date' => '2026-08-03',
            'final_status' => 'half_day',
            'updated_by' => 'importer@example.test',
        ]);
        DB::table('attendance_day_overrides')->insert([
            [
                'emp_id' => 'E001',
                'attendance_date' => '2026-08-05',
                'final_status' => 'half_day',
                'updated_by' => '7',
            ],
            [
                'emp_id' => 'E001',
                'attendance_date' => '2026-08-06',
                'final_status' => 'full_day',
                'updated_by' => '7',
            ],
        ]);

        $controller = $this->app->make(AttendanceManagementController::class);
        $view = $controller->regularizationReport(Request::create(
            '/admin/attendance/regularization-report',
            'GET',
            ['month' => '2026-08']
        ));
        $data = $view->getData();

        $this->assertSame(2, $data['summary']['employees']);
        $this->assertSame(3, $data['summary']['regularizations']);
        $this->assertSame('E001', $data['rows'][0]['emp_id']);
        $this->assertSame(2, $data['rows'][0]['regularization_count']);
        $this->assertSame('Fixture Person 14', $data['rows'][0]['regularizers'][0]['name']);
        $this->assertSame('Calendar Override', $data['rows'][0]['details'][0]['source']);
        $this->assertSame('E002', $data['rows'][1]['emp_id']);
        $this->assertSame(1, $data['rows'][1]['regularization_count']);

        $hoView = $controller->regularizationReport(Request::create(
            '/admin/attendance/regularization-report',
            'GET',
            ['month' => '2026-08', 'location' => 'ho']
        ));
        $hoData = $hoView->getData();
        $this->assertSame(1, $hoData['summary']['regularizations']);
        $this->assertSame('E002', $hoData['rows'][0]['emp_id']);
        $this->assertSame('Head Office', $hoData['rows'][0]['details'][0]['location_label']);

        $stateView = $controller->regularizationReport(Request::create(
            '/admin/attendance/regularization-report',
            'GET',
            ['month' => '2026-08', 'location' => 'state:Karnataka']
        ));
        $stateData = $stateView->getData();
        $this->assertSame(2, $stateData['summary']['regularizations']);
        $this->assertSame('E001', $stateData['rows'][0]['emp_id']);
        $this->assertSame('Karnataka', $stateData['filters']['location_label']);
        $this->assertStringNotContainsString(
            'data-admin-static-serial="true"',
            file_get_contents(resource_path('views/admin/attendance/regularization_report.blade.php'))
        );
    }

    public function test_legacy_direct_override_recovers_actor_from_matching_notification(): void
    {
        DB::table('admins')->insert([
            'id' => 9,
            'name' => 'Fixture Person 17',
            'email' => 'legacy-reviewer@example.test',
        ]);
        $employeeId = DB::table('employee')->insertGetId([
            'empId' => 'E003',
            'name' => 'Fixture Person 18',
            'designation' => 'CSR',
            'assigned_branch_id' => 'BR001',
        ]);
        DB::table('wp_branches_database')->insert([
            'branchId' => 'BR001',
            'branchName' => 'Mysuru',
            'state' => 'Karnataka',
            'city' => 'Mysuru',
        ]);
        DB::table('attendance')->insert([
            'empId' => 'E003',
            'check_in_date' => '2026-09-02',
            'check_in_branch_id' => 'BR001',
            'check_out_branch_id' => 'BR001',
            'attendance_status_override' => 'full_day',
            'attendance_status_override_by' => null,
            'updated_at' => '2026-09-03 10:00:00',
        ]);
        $notificationId = DB::table('admin_notifications')->insertGetId([
            'title' => 'Attendance Regularization Updated',
            'body' => '3 attendance entries from 01 Sep 2026 to 03 Sep 2026 were regularized as Full Day.',
            'sent_by' => 9,
            'sent_at' => '2026-09-03 10:00:05',
            'created_at' => '2026-09-03 10:00:05',
        ]);
        DB::table('employee_notification_deliveries')->insert([
            'admin_notification_id' => $notificationId,
            'employee_id' => $employeeId,
        ]);

        $controller = $this->app->make(AttendanceManagementController::class);
        $view = $controller->regularizationReport(Request::create(
            '/admin/attendance/regularization-report',
            'GET',
            ['month' => '2026-09']
        ));
        $data = $view->getData();

        $this->assertSame('Fixture Person 17', $data['rows'][0]['details'][0]['regularized_by']);
        $this->assertSame('Fixture Person 17', $data['rows'][0]['regularizers'][0]['name']);
    }

    public function test_full_day_remote_uses_work_visit_reviewed_by_and_source(): void
    {
        $employeeId = DB::table('employee')->insertGetId([
            'empId' => 'E004',
            'name' => 'Fixture Person 19',
            'designation' => 'CSR',
            'assigned_branch_id' => 'BR001',
        ]);
        DB::table('wp_branches_database')->insert([
            'branchId' => 'BR001',
            'branchName' => 'Mysuru',
            'state' => 'Karnataka',
            'city' => 'Mysuru',
        ]);
        $attendanceId = DB::table('attendance')->insertGetId([
            'empId' => 'E004',
            'check_in_date' => '2026-09-04',
            'check_in_branch_id' => 'BR001',
            'check_out_branch_id' => 'BR001',
            'attendance_status_override' => 'full_day_remote',
            'attendance_status_override_by' => 'Stored Attendance Actor',
            'updated_at' => '2026-09-04 11:00:00',
        ]);
        DB::table('site_visit_requests')->insert([
            'employee_id' => $employeeId,
            'emp_id' => 'E004',
            'visit_date' => '2026-09-04',
            'status' => 'approved',
            'reviewed_by' => 'work-visit-reviewer@example.test',
            'reviewed_at' => '2026-09-04 11:00:02',
            'attendance_id' => $attendanceId,
        ]);

        $controller = $this->app->make(AttendanceManagementController::class);
        $view = $controller->regularizationReport(Request::create(
            '/admin/attendance/regularization-report',
            'GET',
            ['month' => '2026-09']
        ));
        $detail = $view->getData()['rows'][0]['details'][0];

        $this->assertSame('Full Day Remote', $detail['status_label']);
        $this->assertSame('work-visit-reviewer@example.test', $detail['regularized_by']);
        $this->assertSame('Work Visit', $detail['source']);
    }

    public function test_actor_column_migration_can_be_applied_and_rolled_back(): void
    {
        Schema::table('attendance', function ($table): void {
            $table->dropColumn('attendance_status_override_by');
        });
        $migration = require database_path('migrations/2026_09_04_000001_add_regularized_by_to_attendance_table.php');

        $migration->up();
        $this->assertTrue(Schema::hasColumn('attendance', 'attendance_status_override_by'));

        $migration->down();
        $this->assertFalse(Schema::hasColumn('attendance', 'attendance_status_override_by'));
    }
}
