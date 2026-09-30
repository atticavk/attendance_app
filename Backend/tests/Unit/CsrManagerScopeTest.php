<?php

namespace Tests\Unit;

use App\Models\Employee;
use App\Support\CsrManagerScope;
use Tests\TestCase;

class CsrManagerScopeTest extends TestCase
{
    public function test_scope_includes_csr_and_telecaller_designations(): void
    {
        $query = CsrManagerScope::scopeEligibleEmployeeDesignation(
            Employee::withoutGlobalScopes()
        );

        $this->assertSame(['%CSR%', 'TELECALLER'], $query->getBindings());
        $this->assertStringContainsString('like ?', strtolower($query->toSql()));
        $this->assertStringContainsString('trim', strtolower($query->toSql()));
    }
}
