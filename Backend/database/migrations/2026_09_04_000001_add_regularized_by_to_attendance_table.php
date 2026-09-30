<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('attendance', function (Blueprint $table): void {
            $table->string('attendance_status_override_by')
                ->nullable()
                ->after('attendance_status_override');
        });
    }

    public function down(): void
    {
        Schema::table('attendance', function (Blueprint $table): void {
            $table->dropColumn('attendance_status_override_by');
        });
    }
};
