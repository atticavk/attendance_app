<?php

namespace Tests\Unit;

use App\Models\Admin;
use Illuminate\Support\Facades\Route;
use Tests\TestCase;

class SubHrAccessTest extends TestCase
{
    public function test_subhr_role_is_only_added_to_employee_and_recruitment_business_routes(): void
    {
        $subHrRoutes = collect(Route::getRoutes()->getRoutes())
            ->filter(fn ($route): bool => in_array('subhr', $this->routeRoles($route->getName()), true))
            ->map(fn ($route): ?string => $route->getName())
            ->filter()
            ->values();

        $this->assertNotEmpty($subHrRoutes);
        $this->assertTrue($subHrRoutes->contains('admin-employee-index'));
        $this->assertTrue($subHrRoutes->contains('admin-hiring-index'));
        $this->assertTrue($subHrRoutes->contains('admin-joining-index'));
        $this->assertTrue($subHrRoutes->every(
            fn (string $routeName): bool => str_starts_with($routeName, 'admin-employee-')
                || str_starts_with($routeName, 'admin-hiring-')
                || str_starts_with($routeName, 'admin-joining-')
        ));

        $this->assertNotContains('subhr', $this->routeRoles('admin-branch-index'));
        $this->assertNotContains('subhr', $this->routeRoles('admin-salary-reports'));
        $this->assertNotContains('subhr', $this->routeRoles('admin-attendance-reports'));
        $this->assertNotContains('subhr', $this->routeRoles('admin-messenger'));
    }

    public function test_admin_model_recognizes_subhr_role(): void
    {
        $admin = new Admin(['role' => Admin::ROLE_SUBHR]);

        $this->assertTrue($admin->hasAnyRole([Admin::ROLE_SUBHR]));
        $this->assertFalse($admin->hasAnyRole([Admin::ROLE_HR_ADMIN]));
    }

    private function routeRoles(?string $routeName): array
    {
        if ($routeName === null) {
            return [];
        }

        $route = Route::getRoutes()->getByName($routeName);
        $this->assertNotNull($route, 'Missing route: '.$routeName);

        return collect($route->gatherMiddleware())
            ->filter(fn (string $middleware): bool => str_starts_with($middleware, 'admin.role:'))
            ->flatMap(fn (string $middleware): array => explode(',', substr($middleware, strlen('admin.role:'))))
            ->values()
            ->all();
    }
}
