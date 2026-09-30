<?php

namespace Tests\Unit;

use App\Models\Admin;
use App\Http\Controllers\Admin\AttendanceManagementController;
use App\Support\AdminMenu;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Route;
use ReflectionMethod;
use Tests\TestCase;

class TimingReportAccessTest extends TestCase
{
    public function test_timing_report_is_visible_only_to_md_role(): void
    {
        $this->assertTrue(AdminMenu::adminCanSee(new Admin(['role' => Admin::ROLE_MD]), 'reports.timing'));
        $this->assertFalse(AdminMenu::adminCanSee(new Admin(['role' => Admin::ROLE_HR_ADMIN]), 'reports.timing'));
        $this->assertFalse(AdminMenu::adminCanSee(new Admin(['role' => Admin::ROLE_ZONAL]), 'reports.timing'));
        $this->assertFalse(AdminMenu::adminCanSee(new Admin(['role' => Admin::ROLE_CSR_MANAGER]), 'reports.timing'));
    }

    public function test_regularization_report_is_visible_only_to_md_role(): void
    {
        $this->assertTrue(AdminMenu::adminCanSee(new Admin(['role' => Admin::ROLE_MD]), 'reports.regularization'));
        $this->assertFalse(AdminMenu::adminCanSee(new Admin(['role' => Admin::ROLE_HR_ADMIN]), 'reports.regularization'));
        $this->assertFalse(AdminMenu::adminCanSee(new Admin(['role' => Admin::ROLE_ZONAL]), 'reports.regularization'));
        $this->assertFalse(AdminMenu::adminCanSee(new Admin(['role' => Admin::ROLE_CSR_MANAGER]), 'reports.regularization'));
    }

    public function test_timing_report_route_is_registered_with_menu_authorization(): void
    {
        $route = Route::getRoutes()->getByName('admin-attendance-timing-report');

        $this->assertNotNull($route);
        $this->assertSame('/admin/attendance/timing-report', '/'.$route->uri());
        $this->assertContains('admin.role:md', $route->gatherMiddleware());
    }

    public function test_regularization_report_route_is_registered_with_md_authorization(): void
    {
        $route = Route::getRoutes()->getByName('admin-attendance-regularization-report');

        $this->assertNotNull($route);
        $this->assertSame('/admin/attendance/regularization-report', '/'.$route->uri());
        $this->assertContains('admin.role:md', $route->gatherMiddleware());
    }

    public function test_report_filters_always_initialize_employee_name(): void
    {
        $controller = $this->app->make(AttendanceManagementController::class);
        $method = new ReflectionMethod($controller, 'resolveReportFilters');
        $request = Request::create('/admin/attendance/timing-report', 'GET');

        $filters = $method->invoke($controller, $request);

        $this->assertArrayHasKey('employee_name', $filters);
        $this->assertSame('', $filters['employee_name']);
    }
}
