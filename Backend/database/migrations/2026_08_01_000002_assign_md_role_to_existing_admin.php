<?php

use App\Models\Admin;
use Illuminate\Database\Migrations\Migration;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('admins') || ! Schema::hasColumn('admins', 'role')) {
            return;
        }

        DB::table('admins')
            ->where(function ($query): void {
                $query->whereRaw('LOWER(TRIM(name)) = ?', ['md']);

                if (Schema::hasColumn('admins', 'position')) {
                    $query->orWhereRaw('LOWER(TRIM(position)) IN (?, ?)', ['md', 'managing director']);
                }
            })
            ->where(function ($query): void {
                $query->whereNull('role')
                    ->orWhere('role', '')
                    ->orWhere('role', Admin::ROLE_HR_ADMIN);
            })
            ->update([
                'role' => Admin::ROLE_MD,
                'updated_at' => now(),
            ]);
    }

    public function down(): void
    {
        // Deliberately irreversible: a later intentional role change must not be overwritten.
    }
};
