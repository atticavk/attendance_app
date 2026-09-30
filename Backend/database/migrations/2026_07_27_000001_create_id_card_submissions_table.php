<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;
return new class extends Migration {
 public function up(): void { Schema::create('id_card_submissions', function(Blueprint $table): void { $table->id(); $table->integer('employee_id')->unique(); $table->string('emp_id',50)->unique(); $table->string('full_name'); $table->string('designation'); $table->date('date_of_birth')->nullable(); $table->string('blood_group',5); $table->string('phone',20); $table->string('emergency_contact',20); $table->text('home_address'); $table->string('photo_path'); $table->enum('status',['pending','approved','rejected'])->default('pending'); $table->text('admin_notes')->nullable(); $table->timestamps(); $table->foreign('employee_id')->references('id')->on('employee')->cascadeOnDelete(); }); }
 public function down(): void { Schema::dropIfExists('id_card_submissions'); }
};