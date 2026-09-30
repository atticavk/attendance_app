<?php

use Illuminate\Database\Migrations\Migration;

return new class extends Migration
{
    public function up(): void
    {
        // Historical account provisioning is intentionally disabled. Migrations
        // must not create privileged users or reset existing account passwords.
        // Use attendance:setup-demo explicitly for a fresh local installation.
    }

    public function down(): void
    {
        // Accounts are managed separately from schema migrations.
    }
};
