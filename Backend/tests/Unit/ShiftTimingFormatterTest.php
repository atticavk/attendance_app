<?php

namespace Tests\Unit;

use App\Support\ShiftTimingFormatter;
use Tests\TestCase;

class ShiftTimingFormatterTest extends TestCase
{
    public function test_it_normalizes_short_12_hour_shift_ranges(): void
    {
        $this->assertSame(
            '09:30 AM - 06:00 PM',
            ShiftTimingFormatter::normalize('9:30 AM - 6 PM')
        );
        $this->assertSame(
            '12:00 PM - 09:05 PM',
            ShiftTimingFormatter::normalize('12 pm to 9:05 p.m.')
        );
    }

    public function test_it_uses_the_standard_default_for_missing_or_invalid_ranges(): void
    {
        $this->assertSame('09:30 AM - 07:00 PM', ShiftTimingFormatter::normalize(null));
        $this->assertSame('09:30 AM - 07:00 PM', ShiftTimingFormatter::normalize('day shift'));
    }
}
