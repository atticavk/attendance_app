<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('birthday_sms_settings', function (Blueprint $table): void {
            $table->id();
            $table->boolean('enabled')->default(false);
            $table->time('send_time')->default('09:00:00');
            $table->string('provider_template_id')->nullable();
            $table->text('message_template');
            $table->foreignId('updated_by')->nullable()->constrained('admins')->nullOnDelete();
            $table->timestamps();
        });

        Schema::create('birthday_sms_deliveries', function (Blueprint $table): void {
            $table->id();
            // The legacy employee table uses an integer primary key.
            $table->integer('employee_id');
            $table->date('birthday_date');
            $table->string('phone', 30);
            $table->string('status', 20)->default('pending');
            $table->text('provider_response')->nullable();
            $table->timestamp('sent_at')->nullable();
            $table->timestamps();
            $table->foreign('employee_id')->references('id')->on('employee')->cascadeOnDelete();
            $table->unique(['employee_id', 'birthday_date']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('birthday_sms_deliveries');
        Schema::dropIfExists('birthday_sms_settings');
    }
};
