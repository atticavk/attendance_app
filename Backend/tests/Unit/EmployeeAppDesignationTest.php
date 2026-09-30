<?php

namespace Tests\Unit;

use App\Http\Controllers\EmployeeAuthController;
use ReflectionClass;
use ReflectionMethod;

use Tests\TestCase;

class EmployeeAppDesignationTest extends TestCase
{
    /** @dataProvider designationProvider */
    public function test_app_designation_is_normalized_for_te_tracker(
        string $storedDesignation,
        string $expectedDesignation
    ): void {
        $method = new ReflectionMethod(EmployeeAuthController::class, 'appDesignation');
        $method->setAccessible(true);
        $controller = (new ReflectionClass(EmployeeAuthController::class))
            ->newInstanceWithoutConstructor();

        $this->assertSame(
            $expectedDesignation,
            $method->invoke($controller, $storedDesignation)
        );
    }

    public static function designationProvider(): array
    {
        return [
            'full TE designation' => ['TRANSACTION EXECUTIVE', 'TE'],
            'normalized full TE designation' => [' Transaction Executive ', 'TE'],
            'TE abbreviation' => ['TE', 'TE'],
            'unrelated designation' => ['Branch Manager', 'Branch Manager'],
        ];
    }
}
