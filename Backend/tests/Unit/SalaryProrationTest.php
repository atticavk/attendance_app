<?php

namespace Tests\Unit;

use App\Support\SalaryProration;
use Tests\TestCase;

class SalaryProrationTest extends TestCase
{
    public function test_gross_is_rounded_only_after_exact_proration(): void
    {
        $this->assertSame(483.87, SalaryProration::dailyRate(15000, 31));
        $this->assertSame(12823.0, SalaryProration::grossPayable(15000, 31, 26.5));
    }
}
