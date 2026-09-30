<?php

namespace Tests\Feature;

use App\Support\ProjectAsset;
use Illuminate\Support\Facades\Route;
use Tests\TestCase;

class SecurityBoundaryTest extends TestCase
{
    public function test_admin_employee_directory_requires_authentication(): void
    {
        $this->get('/admin/employee/index')->assertRedirect('/admin/login');
    }

    public function test_shared_vm_and_maintenance_entry_points_are_available(): void
    {
        $this->get('/admin/vm-login')->assertOk();
        $this->get('/admin/vm/attendance')->assertRedirect('/admin/vm-login');
        $this->get('/admin/vm/login')->assertNotFound();

        $this->assertNotNull(Route::getRoutes()->match(request()->create('/test', 'GET')));
        $this->assertNotNull(Route::getRoutes()->match(request()->create('/clear-cache', 'GET')));
        $this->assertNotNull(Route::getRoutes()->match(request()->create('/migrate', 'GET')));
        $this->assertNotNull(Route::getRoutes()->match(request()->create('/optimize', 'GET')));
        $this->assertNotNull(Route::getRoutes()->match(request()->create('/optimize-clear', 'GET')));
    }

    public function test_upload_media_uses_direct_urls(): void
    {
        $url = ProjectAsset::url('storage/private-document.pdf');

        $this->assertStringContainsString('/storage/private-document.pdf', $url);
        $this->assertStringNotContainsString('/media/', $url);
        $this->assertStringNotContainsString('signature=', $url);
    }

    public function test_security_headers_are_added_to_web_responses(): void
    {
        $response = $this->get('/privacy-policy');

        $response->assertOk();
        $response->assertHeader('X-Frame-Options', 'DENY');
        $response->assertHeader('X-Content-Type-Options', 'nosniff');
        $this->assertStringContainsString("default-src 'self'", (string) $response->headers->get('Content-Security-Policy'));
    }

    public function test_cors_is_not_configured_as_a_wildcard(): void
    {
        $this->assertNotContains('*', config('cors.allowed_origins', []));
    }
}
