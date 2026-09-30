<?php

namespace App\Console\Commands;

use App\Models\Admin;
use App\Models\Branch;
use App\Models\Employee;
use App\Models\EmployeeAppCredential;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

class SetupDemo extends Command
{
    protected $signature = 'attendance:setup-demo
        {--yes : Explicitly create fictional data in an empty local database}
        {--latitude=0 : Latitude of the demo branch (-90 to 90)}
        {--longitude=0 : Longitude of the demo branch (-180 to 180)}';

    protected $description = 'Create a local demo admin, active branch and employee with unique passwords';

    public function handle(): int
    {
        if (! app()->environment(['local', 'testing'])) {
            $this->error('Demo setup is only available when APP_ENV is local or testing.');

            return self::FAILURE;
        }

        if (! $this->option('yes')) {
            $this->error('Pass --yes to explicitly create fictional demo data.');

            return self::FAILURE;
        }

        foreach (['admins', 'employee', 'wp_branches_database', 'employee_app_credentials'] as $table) {
            if (! Schema::hasTable($table)) {
                $this->error('Run php artisan migrate before setting up the demo.');

                return self::FAILURE;
            }

            if (DB::table($table)->exists()) {
                $this->error('Demo setup requires empty admin, employee, branch and credential tables. Existing data was not changed.');

                return self::FAILURE;
            }
        }

        $latitude = $this->option('latitude');
        $longitude = $this->option('longitude');
        if (! is_numeric($latitude) || ! is_numeric($longitude)
            || (float) $latitude < -90 || (float) $latitude > 90
            || (float) $longitude < -180 || (float) $longitude > 180) {
            $this->error('Provide valid numeric latitude (-90 to 90) and longitude (-180 to 180).');

            return self::FAILURE;
        }

        $adminPassword = (string) env('ATTENDANCE_DEMO_ADMIN_PASSWORD', Str::random(24));
        $employeePassword = (string) env('ATTENDANCE_DEMO_EMPLOYEE_PASSWORD', Str::random(24));
        if (strlen($adminPassword) < 12 || strlen($employeePassword) < 12) {
            $this->error('Environment-supplied demo passwords must each contain at least 12 characters.');

            return self::FAILURE;
        }

        DB::transaction(function () use ($adminPassword, $employeePassword, $latitude, $longitude): void {
            Admin::query()->create([
                'name' => 'Demo Administrator',
                'email' => 'demo-admin@example.test',
                'role' => Admin::ROLE_HR_ADMIN,
                'password' => Hash::make($adminPassword),
                'password_hint' => '',
            ]);

            Branch::query()->create([
                'branchId' => 'DEMO001',
                'branchName' => 'Demo Branch',
                'addressline' => 'Demonstration location',
                'area' => 'Demo Area',
                'city' => 'Demo City',
                'state' => 'Demo State',
                'pincode' => '000000',
                'latitude' => (string) $latitude,
                'longitude' => (string) $longitude,
                'status' => 1,
            ]);

            $employee = Employee::query()->create([
                'empId' => 'DEMOEMP001',
                'name' => 'Demo Employee',
                'mailId' => 'demo-employee@example.test',
                'designation' => 'BRANCH MANAGER',
                'status' => 'Active',
                'location' => 'Demo Branch',
                'doj' => now()->toDateString(),
                'shift_timing' => '9:30 AM - 6:30 PM',
                'salary' => 0,
            ]);
            $employee->assigned_branch_id = 'DEMO001';
            $employee->save();

            EmployeeAppCredential::query()->create([
                'employee_id' => $employee->id,
                'emp_id' => $employee->empId,
                'branch_id' => 'DEMO001',
                'password_hash' => Hash::make($employeePassword),
                'password_set_at' => now(),
            ]);
        });

        $this->info('Demo created. Store these credentials privately; passwords are not saved in plaintext.');
        $this->line('Admin email: demo-admin@example.test');
        $this->line('Admin password: '.$adminPassword);
        $this->line('Employee branch ID: DEMO001');
        $this->line('Employee ID: DEMOEMP001');
        $this->line('Employee password: '.$employeePassword);
        $this->comment('Set the demo branch coordinates to your test location before checking in with GPS.');

        return self::SUCCESS;
    }
}
