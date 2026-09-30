<?php

namespace Tests\Unit;

use App\Support\MayPfEligibility;
use App\Support\PfSalaryBreakdown;
use Illuminate\Support\Carbon;

use Tests\TestCase;

class PfSalaryBreakdownTest extends TestCase
{
    public function test_it_matches_the_existing_pf_sheet_formula(): void
    {
        $breakdown = PfSalaryBreakdown::forReportRow([
            'state' => 'Karnataka',
            'designation' => 'ABM',
            'salary_days_in_month' => 30,
            'credited_days' => 30,
            'gross_payable_salary' => 30000,
            'advance' => 1000,
            'pf' => 1800,
            'net_payable_salary' => 27200,
        ]);

        $this->assertSame(12750, $breakdown['state_basic_monthly']);
        $this->assertSame(4550, $breakdown['state_da_monthly']);
        $this->assertSame(17300, $breakdown['state_basic_plus_da_monthly']);
        $this->assertSame(12750.0, $breakdown['basic']);
        $this->assertSame(4550.0, $breakdown['da']);
        $this->assertSame(15000, $breakdown['pf_rate_of_wages']);
        $this->assertSame(1800.0, $breakdown['ee_pf']);
        $this->assertSame(0.0, $breakdown['esi']);
        $this->assertSame(0.0, $breakdown['pt']);
        $this->assertSame(27200.0, $breakdown['take_home_salary']);
        $this->assertSame(31800.0, $breakdown['ctc']);
    }

    public function test_it_prorates_tamil_nadu_salary_without_esi_or_pt(): void
    {
        $breakdown = PfSalaryBreakdown::forReportRow([
            'state' => 'Tamil Nadu',
            'designation' => 'Junior',
            'salary_days_in_month' => 30,
            'credited_days' => 15,
            'gross_payable_salary' => 15000,
            'advance' => 0,
            'pf' => 1800,
            'net_payable_salary' => 13200,
        ]);

        $this->assertSame(3345.5, $breakdown['basic']);
        $this->assertSame(3676.5, $breakdown['da']);
        $this->assertSame(842.64, $breakdown['ee_pf']);
        $this->assertSame(0.0, $breakdown['esi']);
        $this->assertSame(0.0, $breakdown['er_esi']);
        $this->assertSame(14157.36, $breakdown['take_home_salary']);
    }

    public function test_take_home_reconciles_to_salary_sheet_net_for_31_day_sample(): void
    {
        $gross = 12823.0;
        $breakdown = PfSalaryBreakdown::forReportRow([
            'state' => 'Andhra Pradesh',
            'designation' => 'ABM',
            'salary_days_in_month' => 31,
            'credited_days' => 26.5,
            'gross_payable_salary' => $gross,
            'advance' => 0,
            'pf' => 1800,
            'net_payable_salary' => 11023,
        ]);

        $this->assertSame($gross, $breakdown['gross_salary']);
        $this->assertSame(0.0, $breakdown['esi']);
        $this->assertSame(0.0, $breakdown['pt']);
        $this->assertSame(11373.54, $breakdown['take_home_salary']);
    }

    public function test_basic_and_da_are_reduced_proportionally_when_they_exceed_gross(): void
    {
        $breakdown = PfSalaryBreakdown::forReportRow([
            'state' => 'Karnataka',
            'designation' => 'ABM',
            'salary_days_in_month' => 31,
            'credited_days' => 26.5,
            'gross_payable_salary' => 12823,
            'advance' => 0,
            'pf' => 1538.76,
            'net_payable_salary' => 11284.24,
        ]);

        $this->assertEqualsWithDelta(12823.0, $breakdown['basic_plus_da'], 0.001);
        $this->assertSame(0, $breakdown['other_allowances']);
        $this->assertEqualsWithDelta(12823.0, $breakdown['gross_salary'], 0.001);
        $this->assertEqualsWithDelta(12750 / 4550, $breakdown['basic'] / $breakdown['da'], 0.001);
    }

    public function test_employee_basic_and_da_override_takes_priority_over_state_and_designation(): void
    {
        $breakdown = PfSalaryBreakdown::forReportRow([
            'emp_id' => '8000112',
            'state' => 'Karnataka',
            'designation' => 'Housekeeping',
            'salary_days_in_month' => 30,
            'credited_days' => 15,
            'gross_payable_salary' => 20000,
            'advance' => 0,
            'pf' => 1800,
            'net_payable_salary' => 18200,
        ]);

        $this->assertSame(21000, $breakdown['state_basic_monthly']);
        $this->assertSame(7000, $breakdown['state_da_monthly']);
        $this->assertSame(10500.0, $breakdown['basic']);
        $this->assertSame(3500.0, $breakdown['da']);
        $this->assertSame(6000.0, $breakdown['other_allowances']);
    }

    public function test_security_deposit_is_included_in_pf_sheet_total_deductions(): void
    {
        $breakdown = PfSalaryBreakdown::forReportRow([
            'state' => 'Karnataka',
            'designation' => 'BM',
            'salary_days_in_month' => 30,
            'credited_days' => 30,
            'gross_payable_salary' => 30000,
            'advance' => 1000,
            'pf' => 1800,
            'security_deposit' => 5000,
            'net_payable_salary' => 22200,
        ]);

        $this->assertSame(5000.0, $breakdown['security_deposit']);
        $this->assertSame(7800.0, $breakdown['total_deductions']);
        $this->assertSame(22200.0, $breakdown['take_home_salary']);
    }

    public function test_employee_pf_is_always_twelve_percent_of_pf_rate_of_wages(): void
    {
        $breakdown = PfSalaryBreakdown::forReportRow([
            'state' => 'Tamil Nadu',
            'designation' => 'TE',
            'salary_days_in_month' => 30,
            'credited_days' => 10,
            'gross_payable_salary' => 10000,
            'advance' => 0,
            'pf' => 1800,
        ]);

        $this->assertEqualsWithDelta(4681.33, $breakdown['pf_rate_of_wages'], 0.01);
        $this->assertSame(561.76, $breakdown['ee_pf']);
        $this->assertSame(561.76, $breakdown['er_pf']);
    }

    /** @dataProvider employeeBasicDaOverrideProvider */
    public function test_employee_basic_and_da_overrides(
        string $empId,
        float $expectedBasic,
        float $expectedDa
    ): void {
        $breakdown = PfSalaryBreakdown::forReportRow([
            'emp_id' => $empId,
            'state' => 'Karnataka',
            'designation' => 'Housekeeping',
            'salary_days_in_month' => 30,
            'credited_days' => 30,
            'gross_payable_salary' => 50000,
            'advance' => 0,
            'pf' => 1800,
            'net_payable_salary' => 48200,
        ]);

        $this->assertSame($expectedBasic, (float) $breakdown['state_basic_monthly']);
        $this->assertSame($expectedDa, (float) $breakdown['state_da_monthly']);
    }

    public function test_pf_export_eligibility_uses_the_may_pf_allowlist(): void
    {
        $this->assertTrue(MayPfEligibility::isEligible(
            Carbon::parse('2026-05-01'),
            null,
            '900000000001'
        ));
        $this->assertFalse(MayPfEligibility::isEligible(
            Carbon::parse('2026-04-01'),
            null,
            '900000000001'
        ));
        $this->assertFalse(MayPfEligibility::isEligible(
            Carbon::parse('2026-06-01'),
            null,
            '999999999999'
        ));
        $this->assertTrue(MayPfEligibility::isEligible(
            Carbon::parse('2026-06-01'),
            null,
            '900000000161'
        ));
        $this->assertTrue(MayPfEligibility::isEligible(
            Carbon::parse('2026-06-01'),
            '9999999',
            '',
            true
        ));
        $this->assertFalse(MayPfEligibility::isEligible(
            Carbon::parse('2026-06-01'),
            null,
            '900000000161',
            false
        ));
        $this->assertSame(1800.0, MayPfEligibility::deductionFor(
            Carbon::parse('2026-06-01'),
            '9999999',
            '',
            0.0,
            true
        ));
        $this->assertSame('900000000001', MayPfEligibility::uanForEmployee('8000001'));
    }

    /** @dataProvider stateDesignationRateProvider */
    public function test_state_and_designation_rates(
        string $state,
        string $designation,
        float $expectedBasic,
        float $expectedDa
    ): void {
        $breakdown = PfSalaryBreakdown::forReportRow([
            'state' => $state,
            'designation' => $designation,
            'salary_days_in_month' => 30,
            'credited_days' => 30,
            'gross_payable_salary' => 50000,
            'advance' => 0,
            'pf' => 1800,
            'net_payable_salary' => 48200,
        ]);

        $this->assertSame($expectedBasic, (float) $breakdown['state_basic_monthly']);
        $this->assertSame($expectedDa, (float) $breakdown['state_da_monthly']);
    }

    public static function stateDesignationRateProvider(): array
    {
        return [
            'KA senior cashier' => ['Karnataka', 'Cashier', 14200, 4550],
            'KA middle ABM' => ['Karnataka', 'ABM', 12750, 4550],
            'KA junior housekeeping' => ['Karnataka', 'Housekeeping', 11600, 4550],
            'AP TE' => ['Andhra Pradesh', 'TE', 4102, 9408],
            'AP ABM' => ['Andhra Pradesh', 'ABM', 4722, 9408],
            'Telangana BM' => ['Telangana', 'BM', 5557, 9408],
            'TN junior TE' => ['Tamil Nadu', 'TE', 6691, 7353],
            'TN gunman' => ['Tamil Nadu', 'Gunman', 8000, 7353],
            'TN ABM' => ['Tamil Nadu', 'ABM', 6880, 7353],
            'TN BM' => ['Tamil Nadu', 'BM', 7390, 7353],
        ];
    }

    public static function employeeBasicDaOverrideProvider(): array
    {
        return [
            'Synthetic employee 1' => ['8000112', 21000, 7000],
            'Synthetic employee 2' => ['8000068', 21000, 7000],
            'Synthetic employee 3' => ['8000097', 12750, 5000],
            'Synthetic employee 4' => ['8000130', 12750, 5000],
            'Synthetic employee 5' => ['8000109', 12750, 5000],
            'Synthetic employee 6' => ['8000107', 15000, 5000],
            'Synthetic employee 7' => ['8000161', 12750, 5000],
            'Synthetic employee 8' => ['8000124', 24000, 7000],
            'Synthetic employee 9' => ['8000103', 15000, 4550],
            'Synthetic employee 10' => ['8000157', 18000, 7000],
            'Synthetic employee 11' => ['8000127', 21000, 7000],
            'Synthetic employee 12' => ['8000117', 16000, 4550],
            'Synthetic employee 13' => ['8000044', 12750, 5000],
            'Synthetic employee 14' => ['8000120', 20000, 7000],
            'Synthetic employee 15' => ['8000102', 12750, 5000],
            'Synthetic employee 16' => ['8000151', 16000, 4550],
            'Synthetic employee 17' => ['8000053', 17000, 6000],
            'Synthetic employee 18' => ['8000078', 17000, 6000],
            'Synthetic employee 19' => ['8000101', 17000, 6000],
            'Synthetic employee 20' => ['8000113', 14000, 6000],
        ];
    }
}
