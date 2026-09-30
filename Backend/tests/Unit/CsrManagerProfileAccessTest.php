<?php

namespace Tests\Unit;

use App\Http\Middleware\EnforceCsrManagerAccess;
use App\Models\Admin;
use Illuminate\Http\Request;
use Illuminate\Routing\Route;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\Exception\HttpException;
use Tests\TestCase;

class CsrManagerProfileAccessTest extends TestCase
{
    /**
     * @dataProvider selfServicePostRouteProvider
     */
    public function test_csr_manager_can_submit_self_service_settings(string $routeName): void
    {
        $request = $this->csrManagerRequest($routeName, 'POST');

        $response = (new EnforceCsrManagerAccess())->handle(
            $request,
            fn (): Response => new Response('allowed')
        );

        $this->assertSame(200, $response->getStatusCode());
        $this->assertSame('allowed', $response->getContent());
    }

    public function test_csr_manager_still_cannot_submit_an_unapproved_admin_route(): void
    {
        $request = $this->csrManagerRequest('admin-employee-update', 'POST');

        $this->expectException(HttpException::class);

        (new EnforceCsrManagerAccess())->handle(
            $request,
            fn (): Response => new Response('not allowed')
        );
    }

    public function test_csr_manager_profile_forms_are_exempt_from_the_read_only_ui_rule(): void
    {
        $profileView = file_get_contents(resource_path('views/admin/profile.blade.php'));
        $passwordView = file_get_contents(resource_path('views/admin/change_password.blade.php'));
        $layoutView = file_get_contents(resource_path('views/admin/layout/app.blade.php'));

        $this->assertSame(2, substr_count($profileView, 'data-csr-self-service-form'));
        $this->assertStringContainsString('data-csr-self-service-form', $passwordView);
        $this->assertStringContainsString(
            'body.csr-manager-readonly form[data-csr-self-service-form]',
            $layoutView
        );
    }

    public function selfServicePostRouteProvider(): array
    {
        return [
            'profile details' => ['admin-profile-details-update'],
            'theme preferences' => ['admin-profile-theme-update'],
            'password' => ['admin-password-update'],
        ];
    }

    private function csrManagerRequest(string $routeName, string $method): Request
    {
        $admin = new Admin();
        $admin->role = Admin::ROLE_CSR_MANAGER;

        $route = (new Route([$method], '/admin/test', fn () => null))->name($routeName);
        $request = Request::create('/admin/test', $method);
        $request->setRouteResolver(fn (): Route => $route);
        $request->setUserResolver(fn (?string $guard = null): Admin => $admin);

        return $request;
    }
}
