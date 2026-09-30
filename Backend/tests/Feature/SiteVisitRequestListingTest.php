<?php

namespace Tests\Feature;

use App\Models\Employee;
use App\Models\SiteVisitRequest;
use Illuminate\Support\Facades\Config;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Laravel\Sanctum\Sanctum;
use Tests\TestCase;

class SiteVisitRequestListingTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();

        Config::set('database.default', 'sqlite');
        Config::set('database.connections.sqlite', [
            'driver' => 'sqlite',
            'database' => ':memory:',
            'prefix' => '',
            'foreign_key_constraints' => true,
        ]);

        DB::purge('sqlite');
        DB::setDefaultConnection('sqlite');
        DB::reconnect('sqlite');

        Schema::create('employee', function ($table): void {
            $table->increments('id');
            $table->string('empId')->unique();
            $table->string('name')->nullable();
        });

        Schema::create('site_visit_requests', function ($table): void {
            $table->increments('id');
            $table->unsignedBigInteger('employee_id');
            $table->string('emp_id', 50);
            $table->date('visit_date');
            $table->string('site_location');
            $table->decimal('latitude', 10, 7);
            $table->decimal('longitude', 10, 7);
            $table->string('photo_path');
            $table->text('reason');
            $table->string('approved_by');
            $table->string('status', 20)->default('pending');
            $table->text('review_note')->nullable();
            $table->string('reviewed_by')->nullable();
            $table->timestamp('reviewed_at')->nullable();
            $table->unsignedBigInteger('attendance_id')->nullable();
            $table->timestamps();
        });
    }

    public function test_site_visit_requests_are_listed_for_current_employee_id(): void
    {
        $employee = Employee::query()->create([
            'empId' => '1000110',
            'name' => 'Fixture Person 2',
        ]);

        SiteVisitRequest::query()->create([
            'employee_id' => $employee->id,
            'emp_id' => '1000110',
            'visit_date' => '2026-05-01',
            'site_location' => 'Client branch',
            'latitude' => 12.9716,
            'longitude' => 77.5946,
            'photo_path' => 'site-visits/test.jpg',
            'reason' => 'Client meeting',
            'approved_by' => 'Manager',
            'status' => 'pending',
        ]);

        Sanctum::actingAs($employee);

        $response = $this->getJson('/api/site-visits');

        $response->assertOk();
        $this->assertCount(1, $response->json('siteVisitRequests'));
        $this->assertSame('2026-05-01', $response->json('siteVisitRequests.0.visitDate'));
    }

    public function test_site_visit_requests_fall_back_to_emp_id_and_repair_ownership(): void
    {
        $employee = Employee::query()->create([
            'empId' => '1000110',
            'name' => 'Fixture Person 2',
        ]);

        $siteVisitRequest = SiteVisitRequest::query()->create([
            'employee_id' => 999999,
            'emp_id' => '1000110',
            'visit_date' => '2026-05-02',
            'site_location' => 'Customer site',
            'latitude' => 12.9716,
            'longitude' => 77.5946,
            'photo_path' => 'site-visits/test-2.jpg',
            'reason' => 'Site audit',
            'approved_by' => 'Manager',
            'status' => 'approved',
        ]);

        Sanctum::actingAs($employee);

        $response = $this->getJson('/api/site-visits');

        $response->assertOk();
        $this->assertCount(1, $response->json('siteVisitRequests'));
        $this->assertSame($siteVisitRequest->id, (int) $response->json('siteVisitRequests.0.id'));

        $siteVisitRequest->refresh();
        $this->assertSame($employee->id, (int) $siteVisitRequest->employee_id);
    }
}
