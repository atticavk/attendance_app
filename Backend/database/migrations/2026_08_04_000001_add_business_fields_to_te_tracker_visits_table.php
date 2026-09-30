<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('te_tracker_visits', function (Blueprint $table): void {
            $table->string('location_type', 20)->default('branch')->after('emp_id');
            $table->string('release_place')->nullable()->after('branch_name');
            $table->decimal('amount', 14, 2)->nullable()->after('distance_from_branch');
            $table->decimal('grams', 12, 3)->nullable()->after('amount');
            $table->decimal('kms', 10, 2)->nullable()->after('grams');
        });
    }

    public function down(): void
    {
        Schema::table('te_tracker_visits', function (Blueprint $table): void {
            $table->dropColumn([
                'location_type',
                'release_place',
                'amount',
                'grams',
                'kms',
            ]);
        });
    }
};
