<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    private const BITLY_URL = 'https://bit.ly/358OOaF';

    private const GOOGLE_MAPS_URL = 'https://www.google.com/maps/place/Attica+Gold+Company+-+Queens+Road+Branch/@12.9880824,77.5989684,17z/data=!4m6!3m5!1s0x3bae1667a5b4b751:0x992adb6a72cfe67b!8m2!3d12.9876025!4d77.5986422!16s%2Fg%2F11b66bypkg?hl=en&entry=ttu';

    public function up(): void
    {
        if (! Schema::hasTable('wp_branches_database') || ! Schema::hasColumn('wp_branches_database', 'url')) {
            return;
        }

        DB::table('wp_branches_database')
            ->where('url', self::BITLY_URL)
            ->update(['url' => self::GOOGLE_MAPS_URL]);
    }

    public function down(): void
    {
        if (! Schema::hasTable('wp_branches_database') || ! Schema::hasColumn('wp_branches_database', 'url')) {
            return;
        }

        DB::table('wp_branches_database')
            ->where('url', self::GOOGLE_MAPS_URL)
            ->update(['url' => self::BITLY_URL]);
    }
};
