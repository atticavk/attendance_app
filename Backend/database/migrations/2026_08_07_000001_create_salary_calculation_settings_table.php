<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('salary_calculation_settings', function (Blueprint $table): void {
            $table->id();
            $table->boolean('fixed_30_days')->default(false);
            $table->boolean('pf_enabled')->default(true);
            $table->foreignId('updated_by')->nullable()->constrained('admins')->nullOnDelete();
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('salary_calculation_settings');
    }
};
