<?php

return [
    /*
    |--------------------------------------------------------------------------
    | Employee ID Card access
    |--------------------------------------------------------------------------
    |
    | Use "agpl000" to enable the feature only when the employee logs in
    | through a branch ID beginning with AGPL000. Change the environment
    | value to "all" to enable it for every authenticated employee without
    | rebuilding the mobile app.
    |
    */
    'employee_access' => env('ID_CARD_EMPLOYEE_ACCESS', 'agpl000'),
];
