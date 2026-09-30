<?php

namespace Tests;

use Illuminate\Foundation\Testing\TestCase as BaseTestCase;

abstract class TestCase extends BaseTestCase
{
    use CreatesApplication;

    protected function setUp(): void
    {
        parent::setUp();

        config()->set('attendance.pf_employees_path', __DIR__.'/Fixtures/pf-employees.json');
        config()->set('attendance.pf_salary_overrides_path', __DIR__.'/Fixtures/pf-salary-overrides.json');
        \App\Support\MayPfEligibility::reset();
    }
}
