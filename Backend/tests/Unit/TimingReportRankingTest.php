<?php

namespace Tests\Unit;

use App\Support\TimingReportRanking;
use Tests\TestCase;

class TimingReportRankingTest extends TestCase
{
    public function test_irregular_ranking_uses_largest_hours_shortfall_and_limits_to_ten(): void
    {
        $rows = collect(range(1, 12))->map(fn (int $index): array => $this->row(
            'Employee '.$index,
            0,
            $index * 3600,
            $index,
            $index,
            $index
        ));

        $ranked = TimingReportRanking::mostIrregular($rows);

        $this->assertCount(10, $ranked);
        $this->assertSame('Employee 12', $ranked->first()['employee_name']);
        $this->assertSame('Employee 3', $ranked->last()['employee_name']);
    }

    public function test_regular_ranking_uses_largest_extra_hours_and_excludes_shortfall(): void
    {
        $rows = collect([
            $this->row('Met Schedule', 0, 0, 0, 0, 0),
            $this->row('One Extra Hour', 3600, 0, 1, 10, 0),
            $this->row('Two Extra Hours', 7200, 0, 2, 20, 0),
            $this->row('Short Hours', 0, 1800, 0, 0, 0),
        ]);

        $ranked = TimingReportRanking::mostRegular($rows);

        $this->assertSame(
            ['Two Extra Hours', 'One Extra Hour', 'Met Schedule'],
            $ranked->pluck('employee_name')->all()
        );
    }

    private function row(
        string $name,
        int $extraHoursSeconds,
        int $hoursShortfallSeconds,
        int $irregularDays,
        float $averageLate,
        float $averageEarly
    ): array {
        return [
            'employee_name' => $name,
            'extra_hours_seconds' => $extraHoursSeconds,
            'hours_shortfall_seconds' => $hoursShortfallSeconds,
            'irregular_days' => $irregularDays,
            'average_late_minutes' => $averageLate,
            'average_early_logout_minutes' => $averageEarly,
            'tracked_days' => 20,
        ];
    }
}
