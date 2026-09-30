<?php

namespace Tests\Feature;

use App\Models\Admin;
use App\Models\EmployeeAppCredential;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Hash;
use Tests\TestCase;

class SetupDemoTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();

        config()->set('database.default', 'sqlite');
        config()->set('database.connections.sqlite.database', ':memory:');
        config()->set('app.key', 'base64:'.base64_encode(random_bytes(32)));
        DB::purge('sqlite');
        DB::setDefaultConnection('sqlite');
        $pdo = DB::connection()->getPdo();
        $pdo->sqliteCreateFunction('CONCAT', fn (...$values) => implode('', $values));
        $pdo->sqliteCreateFunction('LPAD', fn ($value, $length, $pad) => str_pad((string) $value, (int) $length, $pad, STR_PAD_LEFT), 3);
    }

    public function test_all_migrations_run_on_an_empty_database_without_creating_accounts(): void
    {
        $this->assertSame(0, Artisan::call('migrate', ['--force' => true]));
        $this->assertSame(0, DB::table('admins')->count());
        $this->assertSame(0, DB::table('employee')->count());
        $this->assertSame(0, DB::table('wp_branches_database')->count());

        // A second migration run is safe and has no pending schema work.
        $this->assertSame(0, Artisan::call('migrate', ['--force' => true]));
        $this->assertStringContainsString('Nothing to migrate', Artisan::output());
    }

    public function test_demo_is_explicit_and_disabled_in_production(): void
    {
        $this->assertSame(1, Artisan::call('attendance:setup-demo'));
        $this->assertStringContainsString('Pass --yes', Artisan::output());

        $this->app->instance('env', 'production');
        $this->assertSame(1, Artisan::call('attendance:setup-demo', ['--yes' => true]));
        $this->assertStringContainsString('only available', Artisan::output());
    }

    public function test_legacy_baseline_preserves_existing_tables_on_upgrade_and_rollback(): void
    {
        $migration = require database_path('migrations/2014_10_11_000000_create_legacy_employee_and_branch_tables.php');
        $migration->up();
        DB::table('employee')->insert(['empId' => 'EXISTING-DEMO', 'name' => 'Fixture Person 33']);

        $migration->up();
        $migration->down();

        $this->assertDatabaseHas('employee', ['empId' => 'EXISTING-DEMO']);
    }

    public function test_demo_creates_hashed_unique_credentials_and_does_not_overwrite_accounts(): void
    {
        $this->assertSame(0, Artisan::call('migrate', ['--force' => true]));
        $this->assertSame(0, Artisan::call('attendance:setup-demo', [
            '--yes' => true,
            '--latitude' => '12.5',
            '--longitude' => '77.5',
        ]));

        $output = Artisan::output();
        preg_match('/^Admin password: (.+)$/m', $output, $adminMatch);
        preg_match('/^Employee password: (.+)$/m', $output, $employeeMatch);
        $adminPassword = trim($adminMatch[1]);
        $employeePassword = trim($employeeMatch[1]);
        $admin = Admin::query()->firstOrFail();
        $credential = EmployeeAppCredential::query()->firstOrFail();

        $this->assertNotSame($adminPassword, $employeePassword);
        $this->assertGreaterThanOrEqual(12, strlen($adminPassword));
        $this->assertTrue(Hash::check($adminPassword, $admin->password));
        $this->assertTrue(Hash::check($employeePassword, $credential->password_hash));
        $this->assertSame('', $admin->password_hint);
        $this->assertDatabaseHas('wp_branches_database', ['branchId' => 'DEMO001', 'status' => 1, 'latitude' => '12.5']);
        $this->assertDatabaseHas('employee', ['empId' => 'DEMOEMP001', 'assigned_branch_id' => 'DEMO001']);

        $login = $this->postJson('/api/employee/login', [
            'branchId' => 'DEMO001',
            'empId' => 'DEMOEMP001',
            'password' => $employeePassword,
        ]);
        $login->assertOk()->assertJsonPath('employee.empId', 'DEMOEMP001')->assertJsonStructure(['token']);
        $this->withToken($login->json('token'))
            ->getJson('/api/employee/profile')
            ->assertOk()
            ->assertJsonPath('employee.branchId', 'DEMO001');

        foreach (['/api/attendance/history', '/api/salary/summary', '/api/leaves', '/api/notifications'] as $endpoint) {
            $this->withToken($login->json('token'))->getJson($endpoint)->assertOk();
        }

        $this->post('/admin/login', [
            'email' => 'demo-admin@example.test',
            'password' => $adminPassword,
        ])->assertRedirect(route('admin-dashboard'));
        $this->assertAuthenticatedAs($admin, 'admin');

        foreach (['admin-dashboard', 'admin-employee-index', 'admin-attendance-reports'] as $routeName) {
            $this->get(route($routeName))->assertOk();
        }

        $this->assertSame(1, Artisan::call('attendance:setup-demo', ['--yes' => true]));
        $this->assertStringContainsString('Existing data was not changed', Artisan::output());
        $this->assertSame(1, DB::table('admins')->count());
        $this->assertSame($admin->password, $admin->fresh()->password);
    }

    public function test_invalid_coordinates_do_not_create_partial_demo_records(): void
    {
        $this->assertSame(0, Artisan::call('migrate', ['--force' => true]));
        $this->assertSame(1, Artisan::call('attendance:setup-demo', ['--yes' => true, '--latitude' => '91']));
        $this->assertSame(0, DB::table('admins')->count());
        $this->assertSame(0, DB::table('employee')->count());
        $this->assertSame(0, DB::table('wp_branches_database')->count());
    }

    public function test_id_card_migration_repairs_a_partial_run_and_keeps_foreign_key_indexes(): void
    {
        $this->assertSame(0, Artisan::call('migrate', ['--force' => true]));
        $migration = require database_path('migrations/2026_08_10_000001_add_soft_deletes_to_id_card_submissions_table.php');
        $migration->down();
        \Illuminate\Support\Facades\Schema::table('id_card_submissions', fn ($table) => $table->softDeletes());
        $migration->up();
        $migration->up();
        $indexes = collect(DB::select("PRAGMA index_list('id_card_submissions')"))->pluck('name');
        $this->assertContains('id_card_submissions_employee_id_index', $indexes);
        $this->assertContains('id_card_submissions_emp_id_index', $indexes);
        $this->assertNotContains('id_card_submissions_employee_id_unique', $indexes);
        $this->assertNotContains('id_card_submissions_emp_id_unique', $indexes);
        $this->assertNotEmpty(DB::select("PRAGMA foreign_key_list('id_card_submissions')"));
    }
}
