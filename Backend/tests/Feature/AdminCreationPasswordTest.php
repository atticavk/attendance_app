<?php

namespace Tests\Feature;

use App\Models\Admin;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Facades\Schema;
use Tests\TestCase;

class AdminCreationPasswordTest extends TestCase
{
    public function test_created_admins_receive_distinct_passwords_without_plaintext_hints(): void
    {
        config()->set('database.default', 'sqlite');
        config()->set('database.connections.sqlite.database', ':memory:');
        DB::purge('sqlite');

        Schema::create('admins', function ($table): void {
            $table->id();
            foreach (['name', 'email', 'phone', 'address', 'image', 'theme_preference', 'card_style',
                'table_density', 'theme_primary_color', 'theme_background_color', 'theme_surface_color',
                'theme_sidebar_background_color', 'theme_text_color', 'theme_muted_text_color',
                'theme_border_color', 'password', 'password_hint', 'role', 'position'] as $column) {
                $table->string($column)->nullable();
            }
            $table->boolean('sidebar_collapsed')->default(false);
            $table->text('sidebar_menu_permissions')->nullable();
            $table->timestamps();
        });

        $this->withoutMiddleware();
        $passwords = [];

        foreach (['first', 'second'] as $label) {
            $response = $this->post(route('admin-store'), [
                'name' => 'Fixture Person 1',
                'email' => $label.'@example.test',
                'position' => 'Branch Manager',
                'role' => Admin::ROLE_HIRING,
                'sidebar_menu_permissions' => ['dashboard.home'],
            ]);
            $response->assertSessionHasNoErrors()->assertRedirect(route('admin-create'));
            $password = session('created_admin_password');
            $this->assertIsString($password);
            $this->assertGreaterThanOrEqual(20, strlen($password));
            $admin = Admin::query()->where('email', $label.'@example.test')->firstOrFail();
            $this->assertTrue(Hash::check($password, $admin->password));
            $this->assertNull($admin->password_hint);
            $passwords[] = $password;
        }

        $this->assertNotSame($passwords[0], $passwords[1]);
    }
}
