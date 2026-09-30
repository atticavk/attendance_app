<?php

namespace Tests\Unit;

use App\Http\Controllers\Admin\RecruitmentController;
use App\Models\Admin;
use ReflectionClass;
use Tests\TestCase;

class RecruitmentAdminVisibilityTest extends TestCase
{
    /**
     * @dataProvider unrestrictedRoleProvider
     */
    public function test_elevated_recruitment_users_are_not_filtered_by_profile_position(string $role): void
    {
        $admin = new Admin();
        $admin->role = $role;
        $admin->position = 'Managing Director';

        $this->assertNull($this->restrictedPositionFor($admin));
    }

    /**
     * @dataProvider recruitmentOperatorProvider
     */
    public function test_dedicated_recruitment_users_keep_their_position_scope(string $role): void
    {
        $admin = new Admin();
        $admin->role = $role;
        $admin->position = '  Branch   Manager  ';

        $this->assertSame('branch manager', $this->restrictedPositionFor($admin));
    }

    public function unrestrictedRoleProvider(): array
    {
        return [
            'MD' => [Admin::ROLE_MD],
            'HR admin' => [Admin::ROLE_HR_ADMIN],
            'Sub HR' => [Admin::ROLE_SUBHR],
        ];
    }

    public function recruitmentOperatorProvider(): array
    {
        return [
            'Hiring' => [Admin::ROLE_HIRING],
            'Joining' => [Admin::ROLE_JOINING],
        ];
    }

    private function restrictedPositionFor(Admin $admin): ?string
    {
        $reflection = new ReflectionClass(RecruitmentController::class);
        $controller = $reflection->newInstanceWithoutConstructor();
        $method = $reflection->getMethod('restrictedAdminPosition');
        $method->setAccessible(true);

        return $method->invoke($controller, $admin);
    }
}
