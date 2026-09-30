<?php

return [
    // Generate with: php -r "echo password_hash('your-password', PASSWORD_BCRYPT), PHP_EOL;"
    'control_password_hash' => env('MOBILE_API_CONTROL_PASSWORD_HASH'),
    'totp_secret' => env('MOBILE_API_TOTP_SECRET'),
    'totp_issuer' => env('MOBILE_API_TOTP_ISSUER', 'Attica Gold Emergency'),
];
