<?php

use App\Models\Admin;
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('admins', function (Blueprint $table): void {
            if (! Schema::hasColumn('admins', 'role')) {
                $table->string('role')->default('hr_admin')->after('password_hint');
            }
        });

        Admin::query()
            ->whereNull('role')
            ->orWhere('role', '')
            ->update(['role' => Admin::ROLE_HR_ADMIN]);
    }

    public function down(): void
    {
        if (Schema::hasColumn('admins', 'role')) {
            Schema::table('admins', function (Blueprint $table): void {
                $table->dropColumn('role');
            });
        }
    }
};
