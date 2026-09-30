<?php

namespace Tests\Feature;

use App\Models\Admin;
use Illuminate\Support\Facades\Cache;
use App\Support\Totp;
use Tests\TestCase;

class MobileApiControlTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();

        Cache::forget('mobile_api:disabled');
        config()->set('mobile_api.control_password_hash', password_hash('test-password', PASSWORD_BCRYPT));
        config()->set('mobile_api.totp_secret', 'JBSWY3DPEHPK3PXP');

        $this->actingAs(new Admin(['role' => 'md']), 'admin');
    }

    public function test_unauthenticated_user_cannot_view_status_page(): void
    {
        auth('admin')->logout();

        $this->get('/status')->assertUnauthorized();
    }

    public function test_authenticated_admin_can_view_status_page(): void
    {
        $this->actingAs(new Admin(['role' => Admin::ROLE_HR_ADMIN]), 'admin');

        $this->get('/status')->assertOk();
    }

    protected function tearDown(): void
    {
        Cache::forget('mobile_api:disabled');

        parent::tearDown();
    }

    public function test_valid_password_deactivates_mobile_api_until_reactivated(): void
    {
        $this->get('/status')
            ->assertOk()
            ->assertSee('Currently ON');

        $code = app(Totp::class)->currentCode(config('mobile_api.totp_secret'));

        $this->post('/status', ['password' => 'test-password', 'totp_code' => $code, 'action' => 'deactivate'])
            ->assertRedirect('/status');

        $this->getJson('/api/app/update')
            ->assertStatus(503)
            ->assertExactJson(['message' => 'Endpoint error.']);

        $this->get('/status')->assertSee('Currently OFF');

        $this->post('/status', ['password' => 'test-password', 'totp_code' => $code, 'action' => 'activate'])
            ->assertRedirect('/status');

        $this->getJson('/api/app/update')->assertSuccessful();
    }

    public function test_invalid_password_cannot_change_mobile_api_state(): void
    {
        $code = app(Totp::class)->currentCode(config('mobile_api.totp_secret'));

        $this->post('/status', ['password' => 'wrong', 'totp_code' => $code, 'action' => 'deactivate'])
            ->assertSessionHasErrors('password');

        $this->getJson('/api/app/update')->assertSuccessful();
    }

    public function test_invalid_authenticator_code_cannot_change_state(): void
    {
        $this->post('/status', [
            'password' => 'test-password',
            'totp_code' => '000000',
            'action' => 'deactivate',
        ])->assertSessionHasErrors('totp_code');

        $this->getJson('/api/app/update')->assertSuccessful();
    }

    public function test_deactivation_blocks_admin_login_but_not_status_page(): void
    {
        app(\App\Support\MobileApiState::class)->disable();

        $this->get('/admin/login')->assertStatus(503)->assertSee('Endpoint error.');
        $this->post('/admin/login')->assertStatus(503);
        // The shared VM login follows the same server-wide login availability switch.
        $this->get('/admin/vm-login')->assertStatus(503);
        $this->get('/status')->assertOk();
    }
}
