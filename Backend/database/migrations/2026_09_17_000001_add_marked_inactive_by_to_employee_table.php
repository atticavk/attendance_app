<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('employee', function (Blueprint $table): void {
            $table->json('marked_inactive_by')->nullable();
        });
    }

    public function down(): void
    {
        Schema::table('employee', function (Blueprint $table): void {
            $table->dropColumn('marked_inactive_by');
        });
    }
};
