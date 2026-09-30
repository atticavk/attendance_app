<?php

namespace Tests\Unit;

use App\Models\Admin;
use App\Support\AdminMenu;
use Tests\TestCase;

class AdminMenuAccountsTest extends TestCase
{
    public function test_accounts_reports_are_shown_only_in_reports_group(): void
    {
        $admin = new Admin([
            'role' => Admin::ROLE_ACCOUNTS,
            'sidebar_menu_permissions' => [
                'salary.reports',
                'salary.advance_reports',
            ],
        ]);

        $keys = AdminMenu::selectedKeysFor($admin);

        $this->assertContains('reports.salary', $keys);
        $this->assertContains('reports.advance', $keys);
        $this->assertNotContains('salary.reports', $keys);
        $this->assertNotContains('salary.advance_reports', $keys);
    }
}
