<?php

namespace Tests\Unit;

use Tests\TestCase;

class AdminHomeScreenManifestTest extends TestCase
{
    public function test_manifest_uses_attica_red_icons_for_chrome_home_screen(): void
    {
        $manifest = json_decode(
            file_get_contents(public_path('attica-manifest.json')),
            true,
            512,
            JSON_THROW_ON_ERROR
        );

        $this->assertSame('Attica Pagar Admin', $manifest['name']);
        $this->assertSame('Attica', $manifest['short_name']);
        $this->assertSame('../admin/dashboard', $manifest['start_url']);
        $this->assertSame('#760107', $manifest['background_color']);
        $this->assertSame('#760107', $manifest['theme_color']);
        $this->assertSame('maskable', $manifest['icons'][2]['purpose']);

        foreach ([
            'attica-icon-192.png' => [192, 192],
            'attica-icon-512.png' => [512, 512],
            'attica-icon-maskable-512.png' => [512, 512],
            'attica-apple-touch-icon.png' => [180, 180],
        ] as $filename => $expectedSize) {
            $path = public_path('admin/assets/images/'.$filename);
            $this->assertFileExists($path);
            $this->assertSame($expectedSize, array_slice(getimagesize($path), 0, 2));
        }
    }

    public function test_admin_layout_and_login_link_the_manifest_and_touch_icon(): void
    {
        foreach ([
            resource_path('views/admin/layout/app.blade.php'),
            resource_path('views/admin/login.blade.php'),
        ] as $viewPath) {
            $view = file_get_contents($viewPath);

            $this->assertStringContainsString("ProjectAsset::url('attica-manifest.json')", $view);
            $this->assertStringContainsString("ProjectAsset::url('admin/assets/images/attica-apple-touch-icon.png')", $view);
            $this->assertStringContainsString('<meta name="theme-color" content="#760107">', $view);
        }
    }
}
