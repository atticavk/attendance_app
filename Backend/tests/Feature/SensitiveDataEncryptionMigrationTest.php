<?php

namespace Tests\Feature;

use Illuminate\Support\Facades\Config;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Tests\TestCase;

class SensitiveDataEncryptionMigrationTest extends TestCase
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

        Schema::create('employeeDetails', function ($table): void {
            $table->increments('id');
            foreach (['bankAcNo', 'ifscCode', 'aadhaarNo', 'panNo', 'uanNumber'] as $column) {
                $table->text($column)->nullable();
            }
        });
        Schema::create('employee_bank_detail_requests', function ($table): void {
            $table->increments('id');
            $table->text('requested_bank_ac_no')->nullable();
            $table->text('requested_ifsc_code')->nullable();
            $table->text('requested_uan_number')->nullable();
        });
        Schema::create('recruitment_candidates', function ($table): void {
            $table->increments('id');
            $table->text('aadhaar_number')->nullable();
            $table->json('hiring_payload')->nullable();
        });
        Schema::create('admins', function ($table): void {
            $table->increments('id');
            $table->string('password_hint')->nullable();
        });
    }

    public function test_migration_encrypts_identifiers_and_removes_duplicate_aadhaar_json(): void
    {
        DB::table('employeeDetails')->insert([
            'bankAcNo' => '1234567890',
            'ifscCode' => 'TEST0001234',
            'aadhaarNo' => '123456789012',
            'panNo' => 'ABCDE1234F',
            'uanNumber' => '900000000001',
        ]);
        DB::table('employee_bank_detail_requests')->insert([
            'requested_bank_ac_no' => '9876543210',
            'requested_ifsc_code' => 'TEST0004321',
            'requested_uan_number' => '101022301560',
        ]);
        DB::table('recruitment_candidates')->insert([
            'aadhaar_number' => null,
            'hiring_payload' => json_encode(['candidate_name' => 'Test', 'aadhaar_number' => '123456789012']),
        ]);
        DB::table('admins')->insert(['password_hint' => 'unsafe hint']);

        $migration = require database_path('migrations/2026_08_22_000001_encrypt_employee_financial_identifiers.php');
        $migration->up();

        $employeeDetail = DB::table('employeeDetails')->first();
        $candidate = DB::table('recruitment_candidates')->first();
        $payload = json_decode((string) $candidate->hiring_payload, true);

        $this->assertNotSame('1234567890', $employeeDetail->bankAcNo);
        $this->assertStringNotContainsString('123456789012', (string) $candidate->aadhaar_number);
        $this->assertSame(64, strlen((string) $candidate->aadhaar_lookup_hash));
        $this->assertArrayNotHasKey('aadhaar_number', $payload);
        $this->assertSame('', DB::table('admins')->value('password_hint'));
    }
}
