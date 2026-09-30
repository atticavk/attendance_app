<?php

namespace App\Support;

class ShiftTimingFormatter
{
    public const DEFAULT_SHIFT_TIMING = '09:30 AM - 07:00 PM';

    /**
     * Normalize accepted 12-hour shift ranges for display and persistence.
     * Missing or invalid ranges receive the standard company default.
     */
    public static function normalize(?string $value): string
    {
        $value = trim((string) $value);
        if ($value === '') {
            return self::DEFAULT_SHIFT_TIMING;
        }

        $pattern = '/^\s*(\d{1,2})(?:\s*:\s*(\d{1,2}))?\s*([ap])\.?m\.?\s*(?:-|–|—|\bto\b)\s*'
            .'(\d{1,2})(?:\s*:\s*(\d{1,2}))?\s*([ap])\.?m\.?\s*$/i';

        if (preg_match($pattern, $value, $matches) !== 1) {
            return self::DEFAULT_SHIFT_TIMING;
        }

        $startHour = (int) $matches[1];
        $startMinute = isset($matches[2]) && $matches[2] !== '' ? (int) $matches[2] : 0;
        $endHour = (int) $matches[4];
        $endMinute = isset($matches[5]) && $matches[5] !== '' ? (int) $matches[5] : 0;

        if ($startHour < 1 || $startHour > 12 || $endHour < 1 || $endHour > 12
            || $startMinute > 59 || $endMinute > 59) {
            return self::DEFAULT_SHIFT_TIMING;
        }

        return sprintf(
            '%02d:%02d %s - %02d:%02d %s',
            $startHour,
            $startMinute,
            strtoupper($matches[3]).'M',
            $endHour,
            $endMinute,
            strtoupper($matches[6]).'M'
        );
    }
}
