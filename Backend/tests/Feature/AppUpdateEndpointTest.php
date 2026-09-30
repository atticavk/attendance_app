<?php

namespace Tests\Feature;

use Tests\TestCase;

class AppUpdateEndpointTest extends TestCase
{
    public function test_app_update_endpoint_returns_android_update_configuration(): void
    {
        config()->set('mobile_app_update.android', [
            'package_name' => 'app.abhibs.locatoremployee',
            'latest_version' => '5.0.0',
            'latest_build_number' => 5001,
            'minimum_supported_build_number' => 5000,
            'force_update' => true,
            'download_url' => 'https://downloads.example.com/app-arm64-v8a-release.apk',
            'title' => 'Update required',
            'message' => 'Please update now.',
            'release_notes' => ['Bug fixes', 'Performance improvements'],
        ]);

        $response = $this->getJson('/api/app/update');

        $response
            ->assertOk()
            ->assertJson([
                'update' => [
                    'platform' => 'android',
                    'packageName' => 'app.abhibs.locatoremployee',
                    'latestVersion' => '5.0.0',
                    'latestBuildNumber' => 5001,
                    'minimumSupportedBuildNumber' => 5000,
                    'forceUpdate' => true,
                    'downloadUrl' => 'https://downloads.example.com/app-arm64-v8a-release.apk',
                    'title' => 'Update required',
                    'message' => 'Please update now.',
                    'releaseNotes' => ['Bug fixes', 'Performance improvements'],
                ],
            ]);
    }

    public function test_app_update_endpoint_returns_empty_download_url_when_not_configured(): void
    {
        config()->set('mobile_app_update.android', [
            'package_name' => 'app.abhibs.locatoremployee',
            'latest_version' => '5.0.0',
            'latest_build_number' => 5001,
            'minimum_supported_build_number' => 5001,
            'force_update' => true,
            'download_url' => '',
            'title' => 'Update required',
            'message' => 'Please update now.',
            'release_notes' => [],
        ]);

        $response = $this->getJson('/api/app/update');

        $response
            ->assertOk()
            ->assertJsonPath('update.downloadUrl', '');
    }

    public function test_app_update_endpoint_resolves_relative_download_urls_against_request_host(): void
    {
        config()->set('mobile_app_update.android', [
            'package_name' => 'app.abhibs.locatoremployee',
            'latest_version' => '5.0.0',
            'latest_build_number' => 5001,
            'minimum_supported_build_number' => 5000,
            'force_update' => true,
            'download_url' => 'store/redirect',
            'title' => 'Update required',
            'message' => 'Please update now.',
            'release_notes' => [],
        ]);

        $response = $this->withServerVariables([
            'HTTP_HOST' => 'updates.example.com',
            'HTTPS' => 'on',
        ])->getJson('/api/app/update');

        $response->assertOk();

        $downloadUrl = (string) $response->json('update.downloadUrl');

        $this->assertStringStartsWith('http', $downloadUrl);
        $this->assertStringEndsWith('/store/redirect', $downloadUrl);
    }
}
