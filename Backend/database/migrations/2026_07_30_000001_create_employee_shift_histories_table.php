<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('employee_shift_histories', function (Blueprint $table): void {
            $table->id();
            $table->integer('employee_id');
            $table->string('shift_timing');
            $table->date('effective_from');
            $table->unsignedBigInteger('created_by')->nullable();
            $table->timestamps();

            $table->unique(['employee_id', 'effective_from']);
            $table->index(['employee_id', 'effective_from']);
            $table->foreign('employee_id')->references('id')->on('employee')->cascadeOnDelete();
            $table->foreign('created_by')->references('id')->on('admins')->nullOnDelete();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('employee_shift_histories');
    }
};
