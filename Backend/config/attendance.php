<?php

return [
    // A blank value disables VM password login.
    'vm_login_password' => env('VM_LOGIN_PASSWORD', ''),

    // Optional legacy HR account restrictions; keep account identifiers out of source.
    'limited_hr_email' => env('LIMITED_HR_EMAIL', ''),

    // Personal payroll configuration belongs in separately backed-up private storage.
    'pf_employees_path' => env('PF_EMPLOYEES_PATH') ?: storage_path('app/private/may-2026-pf-employees.json'),
    'pf_salary_overrides_path' => env('PF_SALARY_OVERRIDES_PATH') ?: storage_path('app/private/pf-salary-overrides.json'),
];
