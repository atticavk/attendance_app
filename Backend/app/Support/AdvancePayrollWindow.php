<?php

namespace App\Support;

use Illuminate\Support\Carbon;

final class AdvancePayrollWindow
{
    public static function forPayrollMonth(Carbon $payrollMonth): array
    {
        $anchor = $payrollMonth->copy()->startOfMonth();

        return [
            'start' => $anchor->copy()->day(13)->startOfDay(),
            'end' => $anchor->copy()->addMonthNoOverflow()->day(11)->startOfDay(),
        ];
    }

    public static function currentOpenWindowForPayrollMonth(Carbon $payrollMonth, Carbon $date): array
    {
        $window = self::forPayrollMonth($payrollMonth);
        $today = $date->copy()->startOfDay();

        $window['end'] = $today->lt($window['start'])
            ? $window['start']->copy()->subDay()
            : ($today->lt($window['end']) ? $today : $window['end']);

        return $window;
    }

    public static function currentOpenWindow(Carbon $date): ?array
    {
        if ($date->day <= 11) {
            return self::currentOpenWindowForPayrollMonth(
                $date->copy()->subMonthNoOverflow()->startOfMonth(),
                $date
            );
        }

        if ($date->day >= 13) {
            return self::currentOpenWindowForPayrollMonth(
                $date->copy()->startOfMonth(),
                $date
            );
        }

        return null;
    }

    public static function forAdvanceDate(Carbon $advanceDate): ?array
    {
        $date = $advanceDate->copy()->startOfDay();

        if ($date->day <= 11) {
            return self::forPayrollMonth($date->copy()->subMonthNoOverflow()->startOfMonth());
        }

        if ($date->day >= 13) {
            return self::forPayrollMonth($date->copy()->startOfMonth());
        }

        return null;
    }
}
