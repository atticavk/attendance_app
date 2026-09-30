<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasColumn('admins', 'sidebar_menu_permissions')) {
            Schema::table('admins', function (Blueprint $table): void {
                $table->json('sidebar_menu_permissions')->nullable()->after('position');
            });
        }
    }

    public function down(): void
    {
        if (Schema::hasColumn('admins', 'sidebar_menu_permissions')) {
            Schema::table('admins', function (Blueprint $table): void {
                $table->dropColumn('sidebar_menu_permissions');
            });
        }
    }
};
