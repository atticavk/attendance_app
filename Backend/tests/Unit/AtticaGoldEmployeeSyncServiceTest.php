<?php

namespace Tests\Unit;

use App\Models\Employee;
use App\Services\AtticaGoldEmployeeSyncService;
use Illuminate\Support\Facades\Http;
use Tests\TestCase;

class AtticaGoldEmployeeSyncServiceTest extends TestCase
{
    public function test_legacy_sync_url_is_redirected_to_atticagold_biz(): void
    {
        config()->set('services.atticagold_employee_sync.url', 'https://atticagold.in/api/employee-sync.php');
        config()->set('services.atticagold_employee_sync.token', 'test-token');

        Http::fake([
            'https://atticagold.biz/api/employee-sync.php' => Http::response(['ok' => true], 200),
        ]);

        $employee = new Employee([
            'empId' => 'TEST001',
            'name' => 'Fixture Person 4',
            'contact' => '9000000000',
            'mailId' => 'employee@example.test',
            'status' => 'Active',
        ]);

        $result = app(AtticaGoldEmployeeSyncService::class)->sync($employee);

        $this->assertTrue($result['synced']);
        Http::assertSent(fn ($request): bool =>
            $request->url() === 'https://atticagold.biz/api/employee-sync.php'
            && $request->hasHeader('Authorization', 'Bearer test-token')
            && $request['empId'] === 'TEST001'
        );
    }
}
