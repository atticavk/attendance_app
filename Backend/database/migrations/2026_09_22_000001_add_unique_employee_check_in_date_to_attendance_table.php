<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    private const INDEX_NAME = 'attendance_emp_checkin_date_unique';

    public function up(): void
    {
        $this->deduplicateAttendanceRows();

        Schema::table('attendance', function (Blueprint $table): void {
            $table->unique(['empId', 'check_in_date'], self::INDEX_NAME);
        });
    }

    public function down(): void
    {
        Schema::table('attendance', function (Blueprint $table): void {
            $table->dropUnique(self::INDEX_NAME);
        });
    }

    private function deduplicateAttendanceRows(): void
    {
        $duplicateGroups = DB::table('attendance')
            ->select('empId', 'check_in_date')
            ->whereNotNull('empId')
            ->whereNotNull('check_in_date')
            ->groupBy('empId', 'check_in_date')
            ->havingRaw('COUNT(*) > 1')
            ->get();

        foreach ($duplicateGroups as $group) {
            $rows = DB::table('attendance')
                ->where('empId', $group->empId)
                ->where('check_in_date', $group->check_in_date)
                ->orderBy('id')
                ->get();

            $keeper = $rows->last();
            if (! $keeper) {
                continue;
            }

            $updates = [];
            foreach ($this->columnsToMerge() as $column) {
                if ($this->hasValue($keeper->{$column} ?? null)) {
                    continue;
                }

                $source = $rows->first(fn ($row): bool => $this->hasValue($row->{$column} ?? null));
                if ($source) {
                    $updates[$column] = $source->{$column};
                }
            }

            $idsToDelete = $rows->pluck('id')
                ->filter(fn ($id): bool => (int) $id !== (int) $keeper->id)
                ->all();

            if ($idsToDelete !== []) {
                DB::table('attendance')
                    ->whereIn('id', $idsToDelete)
                    ->update([
                        'check_in_submission_id' => null,
                        'check_out_submission_id' => null,
                    ]);
            }

            if ($updates !== []) {
                $updates['updated_at'] = now();
                DB::table('attendance')
                    ->where('id', $keeper->id)
                    ->update($updates);
            }

            if ($idsToDelete !== []) {
                DB::table('attendance')->whereIn('id', $idsToDelete)->delete();
            }
        }
    }

    private function columnsToMerge(): array
    {
        return [
            'check_in_branch_id',
            'check_out_branch_id',
            'photo_path',
            'check_out_photo_path',
            'latitude',
            'longitude',
            'check_out_latitude',
            'check_out_longitude',
            'check_in_time',
            'check_in_distance',
            'check_out_date',
            'check_out_time',
            'check_out_distance',
            'check_in_submission_id',
            'check_out_submission_id',
            'attendance_status_override',
            'attendance_status_override_by',
        ];
    }

    private function hasValue(mixed $value): bool
    {
        return $value !== null && trim((string) $value) !== '';
    }
};
