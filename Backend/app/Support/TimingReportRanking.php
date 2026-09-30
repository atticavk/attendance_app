<?php

namespace App\Support;

use Illuminate\Support\Collection;

final class TimingReportRanking
{
    public static function mostIrregular(Collection $rows, int $limit = 10): Collection
    {
        return $rows
            ->filter(fn (array $row): bool => ($row['hours_shortfall_seconds'] ?? 0) > 0)
            ->sortBy([
                ['hours_shortfall_seconds', 'desc'],
                ['irregular_days', 'desc'],
                ['average_late_minutes', 'desc'],
                ['average_early_logout_minutes', 'desc'],
                ['employee_name', 'asc'],
            ])
            ->take($limit)
            ->values();
    }

    public static function mostRegular(Collection $rows, int $limit = 10): Collection
    {
        return $rows
            ->filter(fn (array $row): bool => ($row['hours_shortfall_seconds'] ?? 0) === 0)
            ->sortBy([
                ['extra_hours_seconds', 'desc'],
                ['irregular_days', 'asc'],
                ['average_late_minutes', 'asc'],
                ['average_early_logout_minutes', 'asc'],
                ['tracked_days', 'desc'],
                ['employee_name', 'asc'],
            ])
            ->take($limit)
            ->values();
    }
}
