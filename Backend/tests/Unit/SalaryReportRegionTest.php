<?php

namespace Tests\Unit;

use App\Support\SalaryReportRegion;
use Tests\TestCase;

class SalaryReportRegionTest extends TestCase
{
    public function test_it_groups_salary_rows_into_the_requested_sheet_order(): void
    {
        $groups = SalaryReportRegion::groups(collect([
            $this->row('HO employee', 'AGPL000', 'Head Office', 'Karnataka', 'Bangalore'),
            $this->row('Bangalore employee', 'AGPL001', 'Indiranagar', 'Karnataka', 'Bengaluru'),
            $this->row('KA employee', 'AGPL002', 'Mysore', 'Karnataka', 'Mysuru'),
            $this->row('AP employee', 'AGPL003', 'Vijayawada', 'Andhra Pradesh', 'Vijayawada'),
            $this->row('TS employee', 'AGPL004', 'Hyderabad', 'Telangana', 'Hyderabad'),
            $this->row('TN employee', 'AGPL005', 'Chennai', 'Tamil Nadu', 'Chennai'),
            $this->row('Pondicherry employee', 'AGPL006', 'Pondicherry', 'Puducherry', 'Puducherry'),
            $this->row('Alternate HO label', 'AGPL999', 'HO', 'Tamil Nadu', 'Chennai'),
        ]));

        $this->assertSame([
            'HO Salary Report',
            'Bangalore Except HO',
            'KA Except Bangalore HO',
            'Andhra Pradesh',
            'Telangana',
            'Tamilnadu Incl Pondicherry',
        ], $groups->pluck('title')->all());
        $this->assertSame(
            ['HO employee', 'Alternate HO label'],
            $groups[0]['rows']->pluck('employee_name')->all()
        );
        $this->assertSame(['Bangalore employee'], $groups[1]['rows']->pluck('employee_name')->all());
        $this->assertSame(['KA employee'], $groups[2]['rows']->pluck('employee_name')->all());
        $this->assertSame(['AP employee'], $groups[3]['rows']->pluck('employee_name')->all());
        $this->assertSame(['TS employee'], $groups[4]['rows']->pluck('employee_name')->all());
        $this->assertSame(
            ['TN employee', 'Pondicherry employee'],
            $groups[5]['rows']->pluck('employee_name')->all()
        );
    }

    private function row(
        string $employeeName,
        string $branchId,
        string $branchName,
        string $state,
        string $city
    ): array {
        return [
            'employee_name' => $employeeName,
            'branch_id' => $branchId,
            'branch_name' => $branchName,
            'state' => $state,
            'city' => $city,
        ];
    }
}
