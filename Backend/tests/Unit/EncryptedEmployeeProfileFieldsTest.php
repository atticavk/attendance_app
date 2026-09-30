<?php

namespace Tests\Unit;

use App\Models\EmployeeBankDetailRequest;
use App\Models\EmployeeDetail;
use Tests\TestCase;

class EncryptedEmployeeProfileFieldsTest extends TestCase
{
    public function test_employee_profile_identifiers_are_encrypted_at_rest_and_plain_when_serialized(): void
    {
        $values = [
            'bankAcNo' => '001234567890',
            'ifscCode' => 'TEST0001234',
            'aadhaarNo' => '123456789012',
            'panNo' => 'ABCDE1234F',
            'uanNumber' => '900000000001',
        ];

        $detail = new EmployeeDetail();
        foreach ($values as $field => $value) {
            $detail->{$field} = $value;
            $this->assertNotSame($value, $detail->getAttributes()[$field]);
            $this->assertSame($value, $detail->{$field});
        }

        $serialized = $detail->toArray();
        foreach ($values as $field => $value) {
            $this->assertSame($value, $serialized[$field]);
        }
    }

    public function test_pending_bank_identifiers_are_encrypted_at_rest_and_plain_when_serialized(): void
    {
        $values = [
            'requested_bank_ac_no' => '009876543210',
            'requested_ifsc_code' => 'TEST0004321',
            'requested_uan_number' => '101022301560',
        ];

        $request = new EmployeeBankDetailRequest();
        foreach ($values as $field => $value) {
            $request->{$field} = $value;
            $this->assertNotSame($value, $request->getAttributes()[$field]);
            $this->assertSame($value, $request->{$field});
        }

        $serialized = $request->toArray();
        foreach ($values as $field => $value) {
            $this->assertSame($value, $serialized[$field]);
        }
    }

    public function test_legacy_plaintext_values_remain_readable_during_migration_window(): void
    {
        $detail = new EmployeeDetail();
        $detail->setRawAttributes([
            'bankAcNo' => '001234567890',
            'ifscCode' => 'TEST0001234',
        ]);

        $this->assertSame('001234567890', $detail->bankAcNo);
        $this->assertSame('TEST0001234', $detail->ifscCode);
    }
}
