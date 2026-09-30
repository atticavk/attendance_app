<?php

namespace Tests\Unit;

use App\Http\Controllers\TeTrackerController;
use App\Models\Employee;

use ReflectionMethod;
use Tests\TestCase;

class TeTrackerDesignationTest extends TestCase
{
    /** @dataProvider allowedDesignationProvider */
    public function test_te_tracker_allows_supported_designations(string $designation): void
    {
        $this->assertTrue($this->isTeEmployee($designation));
    }

    public function test_te_tracker_rejects_other_designations(): void
    {
        $this->assertFalse($this->isTeEmployee('Branch Manager'));
    }

    public static function allowedDesignationProvider(): array
    {
        return [
            'abbreviation' => ['TE'],
            'full designation' => ['TRANSACTION EXECUTIVE'],
            'normalized abbreviation' => [' te '],
            'normalized full designation' => [' Transaction Executive '],
        ];
    }

    private function isTeEmployee(string $designation): bool
    {
        $method = new ReflectionMethod(TeTrackerController::class, 'isTeEmployee');
        $method->setAccessible(true);

        return $method->invoke(
            new TeTrackerController(),
            new Employee(['designation' => $designation])
        );
    }
}
