<?php

namespace Tests\Unit;

use App\Support\MayPfSecurityDeposit;
use Illuminate\Support\Carbon;

use Tests\TestCase;

class MayPfSecurityDepositTest extends TestCase
{
    /** @dataProvider eligibleDesignationProvider */
    public function test_it_deducts_security_deposit_for_eligible_may_pf_designations(string $designation): void
    {
        $this->assertSame(5000.0, MayPfSecurityDeposit::amountFor(
            Carbon::parse('2026-05-01'),
            null,
            '900000000001',
            $designation
        ));
    }

    public function test_it_does_not_deduct_outside_may_2026(): void
    {
        $this->assertSame(0.0, MayPfSecurityDeposit::amountFor(
            Carbon::parse('2026-06-01'),
            null,
            '900000000001',
            'BM',
            true
        ));
    }

    public function test_it_does_not_deduct_for_employee_outside_pf_list_or_other_designation(): void
    {
        $this->assertSame(0.0, MayPfSecurityDeposit::amountFor(
            Carbon::parse('2026-05-01'),
            null,
            '999999999999',
            'BM'
        ));
        $this->assertSame(0.0, MayPfSecurityDeposit::amountFor(
            Carbon::parse('2026-05-01'),
            null,
            '900000000001',
            'Cashier'
        ));
    }

    public function test_it_does_not_deduct_when_employee_is_explicitly_pf_ineligible(): void
    {
        $this->assertSame(0.0, MayPfSecurityDeposit::amountFor(
            Carbon::parse('2026-05-01'),
            null,
            '900000000001',
            'BM',
            false
        ));
    }

    public function test_it_uses_stored_pf_security_deposit_amount_for_may_only(): void
    {
        $this->assertSame(2500.0, MayPfSecurityDeposit::amountFor(
            Carbon::parse('2026-05-01'),
            null,
            '900000000001',
            'BM',
            null,
            2500
        ));

        $this->assertSame(0.0, MayPfSecurityDeposit::amountFor(
            Carbon::parse('2026-06-01'),
            null,
            '900000000001',
            'BM',
            null,
            2500
        ));
    }

    public static function eligibleDesignationProvider(): array
    {
        return [
            'BM' => ['BM'],
            'Branch Manager' => ['Branch Manager'],
            'BM / Branch Manager' => ['BM / Branch Manager'],
            'ABM' => ['ABM'],
            'TE' => ['TE'],
            'Transaction Executive' => ['Transaction Executive'],
            'TE / Transaction Executive' => ['TE / Transaction Executive'],
            'Branch Co Ordinator' => ['Branch Co Ordinator'],
            'Branch Coordinator' => ['Branch Coordinator'],
            'Gun Man' => ['Gun Man'],
            'Gunman' => ['Gunman'],
        ];
    }
}
