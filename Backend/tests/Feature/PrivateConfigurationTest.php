<?php

namespace Tests\Feature;

use App\Support\MayPfEligibility;
use App\Support\PfSalaryBreakdown;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Http;
use Tests\TestCase;

class PrivateConfigurationTest extends TestCase
{
    public function test_vm_login_is_disabled_without_an_explicit_password(): void
    {
        config()->set('attendance.vm_login_password', '');

        $this->post('/admin/vm-login', [
            'username' => 'vm-login',
            'password' => 'arbitrary-test-password',
        ])->assertSessionHas('status', 'Invalid VM password.')
            ->assertSessionMissing('vm_attendance_user');
    }

    public function test_missing_private_payroll_files_use_empty_defaults(): void
    {
        config()->set('attendance.pf_employees_path', storage_path('app/private/missing-test-employees.json'));
        config()->set('attendance.pf_salary_overrides_path', storage_path('app/private/missing-test-overrides.json'));
        MayPfEligibility::reset();

        $this->assertSame([], PfSalaryBreakdown::employeeOverrides());
        $this->assertFalse(MayPfEligibility::isEligible(Carbon::parse('2026-06-01'), 'DEMO001', ''));
        $this->assertTrue(MayPfEligibility::isEligible(Carbon::parse('2026-06-01'), 'DEMO001', '', true));
        $this->assertSame(1800.0, MayPfEligibility::deductionFor(Carbon::parse('2026-06-01'), 'DEMO001', '', 0, true));
    }

    public function test_unconfigured_employee_sync_sends_no_request(): void
    {
        config()->set('services.atticagold_employee_sync.url', '');
        Http::fake();

        $result = (new \App\Services\AtticaGoldEmployeeSyncService())->sync(new \App\Models\Employee());

        $this->assertFalse($result['enabled']);
        Http::assertNothingSent();
    }
}
