<?php

namespace Tests\Unit;

use App\Models\Employee;
use App\Services\NightShiftTimingService;
use Illuminate\Support\Carbon;
use PHPUnit\Framework\TestCase;

class NightShiftTimingServiceTest extends TestCase
{
    public function test_after_midnight_check_in_belongs_to_previous_shift_date(): void
    {
        $employee = new Employee([
            'shift_timing' => '09:00 PM - 06:00 AM',
        ]);

        $date = (new NightShiftTimingService())->shiftDateForCheckIn(
            $employee,
            Carbon::parse('2026-07-31 02:00:00', 'Asia/Kolkata'),
            'Asia/Kolkata'
        );

        $this->assertSame('2026-07-30', $date);
    }

    public function test_evening_check_in_belongs_to_current_shift_date(): void
    {
        $employee = new Employee([
            'shift_timing' => '09:00 PM - 06:00 AM',
        ]);

        $date = (new NightShiftTimingService())->shiftDateForCheckIn(
            $employee,
            Carbon::parse('2026-07-31 20:30:00', 'Asia/Kolkata'),
            'Asia/Kolkata'
        );

        $this->assertSame('2026-07-31', $date);
    }

    public function test_check_in_outside_six_hour_window_has_no_shift_date(): void
    {
        $employee = new Employee([
            'shift_timing' => '09:00 PM - 06:00 AM',
        ]);

        $date = (new NightShiftTimingService())->shiftDateForCheckIn(
            $employee,
            Carbon::parse('2026-07-31 10:00:00', 'Asia/Kolkata'),
            'Asia/Kolkata'
        );

        $this->assertNull($date);
    }
}
