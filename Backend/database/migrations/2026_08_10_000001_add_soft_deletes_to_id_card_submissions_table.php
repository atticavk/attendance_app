<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        // InnoDB must retain an employee_id index for its foreign key. Create
        // replacement indexes before dropping the unique indexes, in separate
        // statements. Check every step so a partially applied DDL run can resume.
        foreach (['employee_id', 'emp_id'] as $column) {
            if (! $this->hasIndex('id_card_submissions_'.$column.'_index')) {
                Schema::table('id_card_submissions', fn (Blueprint $table) => $table->index($column));
            }
        }
        foreach (['employee_id', 'emp_id'] as $column) {
            $index = 'id_card_submissions_'.$column.'_unique';
            if ($this->hasIndex($index)) {
                Schema::table('id_card_submissions', fn (Blueprint $table) => $table->dropUnique($index));
            }
        }
        if (! Schema::hasColumn('id_card_submissions', 'deleted_at')) {
            Schema::table('id_card_submissions', fn (Blueprint $table) => $table->softDeletes()->after('updated_at'));
        }
    }

    public function down(): void
    {
        foreach (['employee_id', 'emp_id'] as $column) {
            if (! $this->hasIndex('id_card_submissions_'.$column.'_unique')) {
                Schema::table('id_card_submissions', fn (Blueprint $table) => $table->unique($column));
            }
            if ($this->hasIndex('id_card_submissions_'.$column.'_index')) {
                Schema::table('id_card_submissions', fn (Blueprint $table) => $table->dropIndex([$column]));
            }
        }
        if (Schema::hasColumn('id_card_submissions', 'deleted_at')) {
            Schema::table('id_card_submissions', fn (Blueprint $table) => $table->dropSoftDeletes());
        }
    }

    private function hasIndex(string $name): bool
    {
        if (DB::getDriverName() === 'sqlite') {
            return collect(DB::select("PRAGMA index_list('id_card_submissions')"))->contains('name', $name);
        }

        return collect(DB::select('SHOW INDEX FROM id_card_submissions'))->contains('Key_name', $name);
    }
};
