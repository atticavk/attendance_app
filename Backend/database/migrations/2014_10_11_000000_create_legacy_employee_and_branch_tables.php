<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        // These two legacy tables predate Laravel. Later migrations extend them.
        if (! Schema::hasTable('employee')) {
            Schema::create('employee', function (Blueprint $table): void {
                $table->integer('id', true);
                $table->string('empId')->nullable();
                $table->string('name')->nullable();
                $table->string('contact')->nullable();
                $table->string('address')->nullable();
                $table->string('designation')->nullable();
                $table->string('status')->nullable()->default('Active');
                $table->date('doj')->nullable();
                $table->string('shift_timing')->nullable();
                $table->string('gender')->nullable();
                $table->string('marital_status')->nullable();
                $table->string('remark')->nullable();
                $table->integer('salary')->nullable();
            });
        }

        if (! Schema::hasTable('wp_branches_database')) {
            Schema::create('wp_branches_database', function (Blueprint $table): void {
                $table->integer('id', true);
                $table->string('branchId');
                $table->string('addressline');
                $table->string('area');
                $table->string('city');
                $table->string('state');
                $table->string('pincode');
                $table->string('branchName')->nullable();
                $table->string('timings', 50)->nullable()->default('9:30 AM - 6:30 PM');
                $table->string('latitude')->nullable();
                $table->string('longitude')->nullable();
                $table->text('url')->nullable();
                $table->integer('status')->default(0);
            });
        }
    }

    public function down(): void
    {
        // Existing installations may already own these tables. Never delete their
        // data on rollback; migrate:fresh remains available for disposable databases.
    }
};
