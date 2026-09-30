<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('employee_app_credentials', function (Blueprint $table): void {
            $table->id();
            $table->unsignedBigInteger('employee_id')->index();
            $table->string('emp_id', 100)->index();
            $table->string('branch_id', 100)->index();
            $table->string('password_hash');
            $table->timestamp('password_set_at')->nullable();
            $table->timestamp('last_login_at')->nullable();
            $table->timestamps();

            $table->unique(['emp_id', 'branch_id'], 'employee_app_credentials_emp_branch_unique');
            $table->index(['branch_id', 'emp_id'], 'employee_app_credentials_branch_emp_idx');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('employee_app_credentials');
    }
};
