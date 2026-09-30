<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('attendance', function (Blueprint $table) {
            $table->uuid('check_in_submission_id')->nullable()->unique();
            $table->uuid('check_out_submission_id')->nullable()->unique();
        });
    }

    public function down(): void
    {
        Schema::table('attendance', function (Blueprint $table) {
            $table->dropUnique(['check_in_submission_id']);
            $table->dropUnique(['check_out_submission_id']);
            $table->dropColumn(['check_in_submission_id', 'check_out_submission_id']);
        });
    }
};
