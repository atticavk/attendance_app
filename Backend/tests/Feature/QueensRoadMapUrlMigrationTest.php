<?php

namespace Tests\Feature;

use Illuminate\Support\Facades\Config;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Tests\TestCase;

class QueensRoadMapUrlMigrationTest extends TestCase
{
    private const BITLY_URL = 'https://bit.ly/358OOaF';

    private const GOOGLE_MAPS_URL = 'https://www.google.com/maps/place/Attica+Gold+Company+-+Queens+Road+Branch/@12.9880824,77.5989684,17z/data=!4m6!3m5!1s0x3bae1667a5b4b751:0x992adb6a72cfe67b!8m2!3d12.9876025!4d77.5986422!16s%2Fg%2F11b66bypkg?hl=en&entry=ttu';

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

        Schema::create('wp_branches_database', function ($table): void {
            $table->increments('id');
            $table->string('branchId')->unique();
            $table->text('url')->nullable();
        });
    }

    public function test_it_replaces_every_exact_match_for_the_known_bitly_url(): void
    {
        DB::table('wp_branches_database')->insert([
            ['branchId' => 'AGPL000', 'url' => self::BITLY_URL],
            ['branchId' => 'AGPL001', 'url' => self::BITLY_URL],
            ['branchId' => 'AGPL003', 'url' => 'https://maps.example.test/already-corrected'],
        ]);

        $migration = require database_path('migrations/2026_08_27_000001_replace_queens_road_bitly_url.php');
        $migration->up();

        $this->assertSame(self::GOOGLE_MAPS_URL, $this->urlFor('AGPL000'));
        $this->assertSame(self::GOOGLE_MAPS_URL, $this->urlFor('AGPL001'));
        $this->assertSame('https://maps.example.test/already-corrected', $this->urlFor('AGPL003'));

        $migration->down();

        $this->assertSame(self::BITLY_URL, $this->urlFor('AGPL000'));
        $this->assertSame(self::BITLY_URL, $this->urlFor('AGPL001'));
    }

    private function urlFor(string $branchId): string
    {
        return (string) DB::table('wp_branches_database')
            ->where('branchId', $branchId)
            ->value('url');
    }
}
