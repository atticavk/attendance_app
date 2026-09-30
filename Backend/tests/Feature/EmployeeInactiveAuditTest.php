<?php

namespace Tests\Feature;

use App\Http\Controllers\Admin\EmployeeController;
use App\Models\Admin;
use App\Models\Employee;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Tests\TestCase;

class EmployeeInactiveAuditTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();
        config(['database.default' => 'sqlite', 'database.connections.sqlite' => [
            'driver' => 'sqlite', 'database' => ':memory:', 'prefix' => '',
        ]]);
        DB::purge('sqlite');
        Schema::create('employee', function ($table): void {
            $table->increments('id');
            $table->string('empId')->nullable();
            $table->string('status')->nullable();
            $table->text('inactive_reason')->nullable();
            $table->date('last_working_date')->nullable();
        });
        (require database_path('migrations/2026_09_17_000001_add_marked_inactive_by_to_employee_table.php'))->up();
        (require database_path('migrations/2019_12_14_000001_create_personal_access_tokens_table.php'))->up();
        $this->withoutMiddleware();
    }

    public function test_inactive_records_authenticated_actor_and_preserves_snapshot_on_reactivation(): void
    {
        $actor = new Admin(['id' => 91, 'name' => 'Fixture Person 10', 'role' => 'hr_admin']);
        $this->actingAs($actor, 'admin');
        $employee = Employee::create(['empId' => 'TEST-1', 'status' => 'Active']);
        $employee->createToken('test-session');

        $this->post('/admin/employee/inactive/'.$employee->id, [
            'inactive_reason' => ' Test reason ',
            'last_working_date' => '2026-09-17',
            'marked_inactive_by' => ['admin_id' => 999, 'name' => 'Fixture Person 11'],
        ])->assertRedirect();

        $employee->refresh();
        $expected = ['admin_id' => 91, 'name' => 'Fixture Person 10', 'empId' => null, 'role' => 'hr_admin'];
        $this->assertSame('Inactive', $employee->status);
        $this->assertSame('Test reason', $employee->inactive_reason);
        $this->assertSame($expected, $employee->marked_inactive_by);
        $this->assertSame(0, $employee->tokens()->count());
        $this->assertArrayNotHasKey('marked_inactive_by', $employee->toArray());
        app(EmployeeController::class)->active($employee->id);
        $this->assertSame($expected, $employee->fresh()->marked_inactive_by);
        $this->assertSame('Active', $employee->fresh()->status);

        $actor->name = 'Next Operator Name';
        $this->post('/admin/employee/inactive/'.$employee->id, [
            'inactive_reason' => 'Second action', 'last_working_date' => '2026-09-17',
        ])->assertRedirect();
        $this->assertSame('Next Operator Name', $employee->fresh()->marked_inactive_by['name']);
    }

    public function test_missing_actor_cannot_change_employee(): void
    {
        $employee = Employee::create(['status' => 'Active']);
        $this->post('/admin/employee/inactive/'.$employee->id, [
            'inactive_reason' => 'Test reason', 'last_working_date' => '2026-09-17',
        ])->assertStatus(401);
        $this->assertSame('Active', $employee->fresh()->status);
        $this->assertNull($employee->fresh()->marked_inactive_by);
    }
}
