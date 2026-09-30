<?php

namespace Tests\Unit;

use App\Http\Controllers\Admin\EmployeeController;
use App\Models\Employee;
use Illuminate\Http\Request;
use Illuminate\Support\Collection;
use Tests\TestCase;
use ReflectionClass;

class EmployeeDirectoryPaginationTest extends TestCase
{
    public function test_employee_directory_collection_is_limited_to_fifty_rows_per_page(): void
    {
        $controller = (new ReflectionClass(EmployeeController::class))->newInstanceWithoutConstructor();
        $method = (new ReflectionClass(EmployeeController::class))->getMethod('paginateEmployeeCollection');
        $request = Request::create('/admin/employee/index', 'GET', ['page' => 2]);
        $employees = new Collection(range(1, 125));

        $paginator = $method->invoke($controller, $employees, $request);

        $this->assertSame(125, $paginator->total());
        $this->assertSame(50, $paginator->perPage());
        $this->assertSame(2, $paginator->currentPage());
        $this->assertSame(range(51, 100), $paginator->items());
    }

    public function test_employee_directory_search_matches_employee_and_branch_fields(): void
    {
        $controller = (new ReflectionClass(EmployeeController::class))->newInstanceWithoutConstructor();
        $method = (new ReflectionClass(EmployeeController::class))->getMethod('employeeMatchesDirectorySearch');
        $employee = new Employee([
            'empId' => 'AGPL123',
            'name' => 'Fixture Person 34',
            'designation' => 'Branch Manager',
            'status' => 'Active',
        ]);
        $employee->last_login_branch_name = 'Jayanagar';
        $employee->last_login_branch_city = 'Bengaluru';

        $this->assertTrue($method->invoke($controller, $employee, 'fixture person'));
        $this->assertTrue($method->invoke($controller, $employee, 'AGPL123'));
        $this->assertTrue($method->invoke($controller, $employee, 'bengaluru'));
        $this->assertFalse($method->invoke($controller, $employee, 'Chennai'));
    }
}
