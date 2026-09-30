<?php

namespace App\Services;

use App\Models\Attendance;
use App\Models\Employee;
use App\Models\EmployeeShiftHistory;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Schema;

class AttendanceClassificationService
{
    public const STATUS_FULL_DAY = 'full_day';

    public const STATUS_HALF_DAY = 'half_day';

    public const STATUS_SINGLE_PUNCH = 'single_punch';

    public const STATUS_ABSENT = 'absent';

    public const PUNCH_GRACE_MINUTES = 10;

    public const DURATION_GRACE_MINUTES = 20;

    private const DEFAULT_SHIFT_TIMING = '10:00 AM - 7:00 PM';

    /** @var array<string, Employee|null> */
    private array $employeeCache = [];

    /** @var array<string, string> */
    private array $shiftTimingCache = [];

    /** @var array<int|string, \Illuminate\Support\Collection<int, EmployeeShiftHistory>> */
    private array $shiftHistoryCache = [];

    private ?bool $shiftHistoryTableExists = null;

    public function primeEmployees(iterable $employees): void
    {
        foreach ($employees as $employee) {
            if (! $employee instanceof Employee) {
                continue;
            }

            $empId = $this->clean($employee->empId);

            if ($empId !== '') {
                $this->employeeCache[$empId] = $employee;
            }
        }
    }

    public function primeEmployeeIds(iterable $empIds): void
    {
        $missingIds = collect($empIds)
            ->map(fn ($empId): string => $this->clean($empId))
            ->filter()
            ->unique()
            ->reject(fn (string $empId): bool => array_key_exists($empId, $this->employeeCache))
            ->values();

        if ($missingIds->isEmpty()) {
            return;
        }

        try {
            $employees = Employee::query()
                ->when(
                    $this->hasShiftHistoryTable() && method_exists(Employee::class, 'shiftHistories'),
                    fn ($query) => $query->with('shiftHistories')
                )
                ->whereIn('empId', $missingIds->all())
                ->get(['id', 'empId', 'shift_timing']);

            $this->primeEmployees($employees);

            foreach ($missingIds as $empId) {
                $this->employeeCache[$empId] ??= null;
            }
        } catch (\Throwable) {
            // Individual lookups retain the existing fallback behavior.
        }
    }

    public function calculatedStatus(Attendance $attendance, ?Employee $employee = null): string
    {
        if ($this->clean($attendance->check_in_date) === '' || $this->clean($attendance->check_in_time) === '') {
            return self::STATUS_ABSENT;
        }

        if ($this->clean($attendance->check_out_date) === '' || $this->clean($attendance->check_out_time) === '') {
            return self::STATUS_SINGLE_PUNCH;
        }

        return $this->isFullDay(
            $this->clean($attendance->empId),
            $this->clean($attendance->check_in_date),
            $this->clean($attendance->check_in_time),
            $this->clean($attendance->check_out_date),
            $this->clean($attendance->check_out_time),
            null,
            $employee
        ) ? self::STATUS_FULL_DAY : self::STATUS_HALF_DAY;
    }

    public function calculatedImportedStatus(
        string $empId,
        string $attendanceDate,
        ?string $firstLogin,
        ?string $lastLogout,
        ?int $loggedSeconds = null,
        ?Employee $employee = null
    ): string {
        $firstLogin = $this->clean($firstLogin);
        $lastLogout = $this->clean($lastLogout);

        if ($firstLogin === '' && $lastLogout === '') {
            return self::STATUS_ABSENT;
        }

        if ($firstLogin === '' || $lastLogout === '') {
            return self::STATUS_SINGLE_PUNCH;
        }

        $checkOutDate = $attendanceDate;
        $shiftRange = $this->shiftRange($empId, $attendanceDate, $employee);

        try {
            $checkIn = Carbon::parse($attendanceDate.' '.$firstLogin, $this->timezone());
            $checkOut = Carbon::parse($attendanceDate.' '.$lastLogout, $this->timezone());

            if (! $shiftRange['end']->isSameDay($shiftRange['start']) && $checkOut->lte($checkIn)) {
                $checkOutDate = Carbon::parse($attendanceDate, $this->timezone())->addDay()->toDateString();
            }
        } catch (\Throwable) {
            return self::STATUS_HALF_DAY;
        }

        return $this->isFullDay(
            $this->clean($empId),
            $attendanceDate,
            $firstLogin,
            $checkOutDate,
            $lastLogout,
            $loggedSeconds,
            $employee,
            $shiftRange
        ) ? self::STATUS_FULL_DAY : self::STATUS_HALF_DAY;
    }

    public function shiftTimingForDate(string $empId, string $attendanceDate, ?Employee $employee = null): string
    {
        $employee ??= $this->employeeFor($empId);

        if (! $employee instanceof Employee) {
            return self::DEFAULT_SHIFT_TIMING;
        }

        $date = Carbon::parse($attendanceDate, $this->timezone())->toDateString();
        $cacheKey = (string) $employee->getKey().'|'.$date;

        if (array_key_exists($cacheKey, $this->shiftTimingCache)) {
            return $this->shiftTimingCache[$cacheKey];
        }

        $historyTiming = $this->shiftTimingFromLoadedHistory($employee, $date);

        if ($historyTiming === null && ! $employee->relationLoaded('shiftHistories')) {
            $historyTiming = $this->shiftTimingFromDatabase($employee, $date);
        }

        return $this->shiftTimingCache[$cacheKey] = $historyTiming
            ?: ($this->clean($employee->shift_timing) ?: self::DEFAULT_SHIFT_TIMING);
    }

    /**
     * @param  array{start: Carbon, end: Carbon}|null  $resolvedShiftRange
     */
    private function isFullDay(
        string $empId,
        string $checkInDate,
        string $checkInTime,
        string $checkOutDate,
        string $checkOutTime,
        ?int $loggedSeconds,
        ?Employee $employee,
        ?array $resolvedShiftRange = null
    ): bool {
        try {
            $checkIn = Carbon::parse($checkInDate.' '.$checkInTime, $this->timezone());
            $checkOut = Carbon::parse($checkOutDate.' '.$checkOutTime, $this->timezone());
        } catch (\Throwable) {
            return false;
        }

        if ($checkOut->lte($checkIn)) {
            return false;
        }

        $shiftRange = $resolvedShiftRange ?? $this->shiftRange($empId, $checkInDate, $employee);
        $punchGraceSeconds = self::PUNCH_GRACE_MINUTES * 60;
        $checkInWithinWindow = $checkIn->betweenIncluded(
            $shiftRange['start']->copy()->subSeconds($punchGraceSeconds),
            $shiftRange['start']->copy()->addSeconds($punchGraceSeconds)
        );
        $checkOutWithinWindow = $checkOut->betweenIncluded(
            $shiftRange['end']->copy()->subSeconds($punchGraceSeconds),
            $shiftRange['end']->copy()->addSeconds($punchGraceSeconds)
        );

        if ($checkInWithinWindow && $checkOutWithinWindow) {
            return true;
        }

        $workedSeconds = $loggedSeconds !== null && $loggedSeconds > 0
            ? $loggedSeconds
            : (int) $checkIn->diffInSeconds($checkOut);
        $scheduledSeconds = (int) $shiftRange['start']->diffInSeconds($shiftRange['end']);
        $minimumFullDaySeconds = max(0, $scheduledSeconds - (self::DURATION_GRACE_MINUTES * 60));

        return $workedSeconds >= $minimumFullDaySeconds;
    }

    /**
     * @return array{start: Carbon, end: Carbon}
     */
    private function shiftRange(string $empId, string $attendanceDate, ?Employee $employee = null): array
    {
        $timing = $this->shiftTimingForDate($empId, $attendanceDate, $employee);
        [$startTime, $endTime] = $this->extractTimingRange($timing);

        if ($startTime === null || $endTime === null) {
            [$startTime, $endTime] = $this->extractTimingRange(self::DEFAULT_SHIFT_TIMING);
        }

        $start = Carbon::parse($attendanceDate.' '.$startTime, $this->timezone());
        $end = Carbon::parse($attendanceDate.' '.$endTime, $this->timezone());

        if ($end->lte($start)) {
            $end->addDay();
        }

        return ['start' => $start, 'end' => $end];
    }

    /**
     * @return array{0: string|null, 1: string|null}
     */
    private function extractTimingRange(string $value): array
    {
        preg_match_all(
            '/\d{1,2}(?::\d{2})?(?::\d{2})?\s*(?:[APap][Mm])?/',
            str_replace([' to ', ' TO ', '–', '—'], '-', $value),
            $matches
        );

        $times = collect($matches[0] ?? [])
            ->map(fn ($time): ?string => $this->normalizeTime($time))
            ->filter()
            ->values();

        return [$times->get(0), $times->get(1)];
    }

    private function normalizeTime(?string $value): ?string
    {
        $value = $this->clean($value);

        if ($value === '') {
            return null;
        }

        foreach (['H:i:s', 'H:i', 'g:i A', 'g:iA', 'h:i A', 'h:iA', 'g A', 'gA', 'h A', 'hA'] as $format) {
            try {
                return Carbon::createFromFormat($format, strtoupper($value), $this->timezone())->format('H:i:s');
            } catch (\Throwable) {
                continue;
            }
        }

        try {
            return Carbon::parse($value, $this->timezone())->format('H:i:s');
        } catch (\Throwable) {
            return null;
        }
    }

    private function employeeFor(string $empId): ?Employee
    {
        $empId = $this->clean($empId);

        if ($empId === '') {
            return null;
        }

        if (array_key_exists($empId, $this->employeeCache)) {
            return $this->employeeCache[$empId];
        }

        try {
            return $this->employeeCache[$empId] = Employee::query()
                ->whereRaw('TRIM(empId) = ?', [$empId])
                ->first();
        } catch (\Throwable) {
            return $this->employeeCache[$empId] = null;
        }
    }

    private function shiftTimingFromLoadedHistory(Employee $employee, string $date): ?string
    {
        if (! $employee->relationLoaded('shiftHistories')) {
            return null;
        }

        $history = $employee->getRelation('shiftHistories')
            ->filter(fn ($item): bool => $this->clean($item->effective_from) !== ''
                && Carbon::parse($item->effective_from, $this->timezone())->toDateString() <= $date)
            ->sortByDesc(fn ($item): string => Carbon::parse($item->effective_from, $this->timezone())->toDateString())
            ->first();

        return $history ? $this->clean($history->shift_timing) : null;
    }

    private function shiftTimingFromDatabase(Employee $employee, string $date): ?string
    {
        if (! $employee->getKey() || ! $this->hasShiftHistoryTable()) {
            return null;
        }

        try {
            $employeeKey = $employee->getKey();

            if (! array_key_exists($employeeKey, $this->shiftHistoryCache)) {
                $this->shiftHistoryCache[$employeeKey] = EmployeeShiftHistory::query()
                    ->where('employee_id', $employeeKey)
                    ->orderByDesc('effective_from')
                    ->orderByDesc('id')
                    ->get(['id', 'employee_id', 'shift_timing', 'effective_from']);
            }

            $history = $this->shiftHistoryCache[$employeeKey]
                ->first(fn (EmployeeShiftHistory $item): bool => Carbon::parse(
                    $item->effective_from,
                    $this->timezone()
                )->toDateString() <= $date);

            return $history ? ($this->clean($history->shift_timing) ?: null) : null;
        } catch (\Throwable) {
            return null;
        }
    }

    private function hasShiftHistoryTable(): bool
    {
        if ($this->shiftHistoryTableExists !== null) {
            return $this->shiftHistoryTableExists;
        }

        try {
            return $this->shiftHistoryTableExists = Schema::hasTable('employee_shift_histories');
        } catch (\Throwable) {
            return $this->shiftHistoryTableExists = false;
        }
    }

    private function timezone(): string
    {
        return (string) config('app.timezone', 'Asia/Kolkata');
    }

    private function clean(mixed $value): string
    {
        return trim((string) $value);
    }
}
