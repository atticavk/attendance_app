<?php

return [
    'android' => [
        'package_name' => env('APP_UPDATE_ANDROID_PACKAGE_NAME', 'app.abhibs.locatoremployee'),
        'latest_version' => env('APP_UPDATE_ANDROID_LATEST_VERSION', '5.0.34'),
        'latest_build_number' => (int) env('APP_UPDATE_ANDROID_LATEST_BUILD', 5035),
        'minimum_supported_build_number' => (int) env('APP_UPDATE_ANDROID_MIN_SUPPORTED_BUILD', 5035),
        'force_update' => (bool) env('APP_UPDATE_ANDROID_FORCE', true),
        'download_url' => env(
            'APP_UPDATE_ANDROID_DOWNLOAD_URL',
            'https://play.google.com/store/apps/details?id=app.abhibs.locatoremployee'
        ),
        'title' => env('APP_UPDATE_ANDROID_TITLE', 'Update required'),
        'message' => env(
            'APP_UPDATE_ANDROID_MESSAGE',
            'A newer version of Attica Attendance is available. Please update the app to continue.'
        ),
        'release_notes' => preg_split('/\r\n|\r|\n/', (string) env('APP_UPDATE_ANDROID_RELEASE_NOTES', '')) ?: [],
    ],
];
