<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('branch_opening_assignments')) {
            Schema::create('branch_opening_assignments', function (Blueprint $table): void {
                $table->id();
                $table->string('branch_id', 50);
                $table->unsignedBigInteger('employee_id');
                $table->string('assignment_type', 30);
                $table->unsignedBigInteger('assigned_by')->nullable();
                $table->timestamps();

                $table->unique(['branch_id', 'employee_id', 'assignment_type'], 'branch_opening_assignment_unique');
                $table->index(['branch_id', 'assignment_type']);
                $table->index('employee_id');
            });
        }

    }

    public function down(): void
    {
        Schema::dropIfExists('branch_opening_assignments');
    }
};
