<?php

namespace App\Services;

use App\Models\Attendance;
use App\Models\Branch;
use App\Models\Employee;
use Illuminate\Support\Carbon;

class AttendancePunctualityService
{
    private const DEFAULT_SHIFT_START = '10:00:00';

    private const DEFAULT_SHIFT_END = '19:00:00';

    private const GRACE_PERIOD_MINUTES = 10;

    private AttendanceClassificationService $attendanceClassificationService;

    public function __construct(?AttendanceClassificationService $attendanceClassificationService = null)
    {
        $this->attendanceClassificationService = $attendanceClassificationService
            ?? new AttendanceClassificationService();
    }

    public function analyzeEmployee(
        Employee $employee,
        array $appRecordsByDate,
        array $importedRecordsByDate,
        ?Branch $branch,
        Carbon $start,
        Carbon $end
    ): array {
        $lateDaysCount = 0;
        $earlyLogoutDaysCount = 0;
        $trackedDaysCount = 0;
        $expectedSeconds = 0;
        $workedSeconds = 0;
        $totalLateMinutes = 0;
        $totalEarlyLogoutMinutes = 0;
        $details = [];
        $scheduleLabels = [];
        $cursor = $start->copy()->startOfDay();

        while ($cursor->lte($end)) {
            $date = $cursor->toDateString();
            $importedRecord = $importedRecordsByDate[$date] ?? null;
            /** @var Attendance|null $appRecord */
            $appRecord = $appRecordsByDate[$date] ?? null;
            $source = $importedRecord ? 'HO Attendance' : ($appRecord ? 'App Attendance' : '');

            if ($source === '') {
                $cursor->addDay();

                continue;
            }

            $trackedDaysCount++;
            $schedule = $this->resolveSchedule($employee, $cursor);
            $scheduleLabels[$schedule['label']] = true;
            $expectedSeconds += $schedule['duration_seconds'];
            $workedSeconds += $this->workedSeconds($appRecord, $importedRecord, $date);

            $checkInTime = $importedRecord['first_login'] ?? $appRecord?->check_in_time;
            $checkOutTime = $importedRecord['last_logout'] ?? $appRecord?->check_out_time;
            $lateMinutes = $this->lateMinutes($checkInTime, $schedule['start']);
            $earlyLogoutMinutes = $this->earlyLogoutMinutes(
                $checkOutTime,
                $schedule['start'],
                $schedule['end']
            );
            $wasLate = $lateMinutes > 0;
            $wasEarly = $earlyLogoutMinutes > 0;

            if ($wasLate) {
                $lateDaysCount++;
                $totalLateMinutes += $lateMinutes;
            }

            if ($wasEarly) {
                $earlyLogoutDaysCount++;
                $totalEarlyLogoutMinutes += $earlyLogoutMinutes;
            }

            if ($wasLate || $wasEarly) {
                $details[] = [
                    'date' => $date,
                    'date_label' => $cursor->format('d M Y'),
                    'source' => $source,
                    'check_in' => $this->formatDisplayTime($checkInTime),
                    'check_out' => $this->formatDisplayTime($checkOutTime),
                    'shift_start' => $schedule['start_label'],
                    'shift_end' => $schedule['end_label'],
                    'was_late' => $wasLate,
                    'was_early_logout' => $wasEarly,
                    'late_minutes' => $lateMinutes,
                    'late_label' => $wasLate ? $lateMinutes.' min late' : '--',
                    'early_logout_minutes' => $earlyLogoutMinutes,
                    'early_logout_label' => $wasEarly ? $earlyLogoutMinutes.' min early' : '--',
                ];
            }

            $cursor->addDay();
        }

        return [
            'late_days_count' => $lateDaysCount,
            'early_logout_days_count' => $earlyLogoutDaysCount,
            'irregular_days_count' => count($details),
            'tracked_days_count' => $trackedDaysCount,
            'regular_days_count' => max($this->dateSpanDays($start, $end) - count($details), 0),
            'schedule_label' => count($scheduleLabels) > 1
                ? 'Varies by attendance date'
                : (array_key_first($scheduleLabels)
                    ?? $this->resolveSchedule($employee, $start)['label']),
            'schedule_labels' => array_keys($scheduleLabels) ?: [
                $this->resolveSchedule($employee, $start)['label'],
            ],
            'expected_seconds' => $expectedSeconds,
            'worked_seconds' => $workedSeconds,
            'hours_completion_percent' => $expectedSeconds > 0
                ? round(min($workedSeconds / $expectedSeconds, 1) * 100, 1)
                : 0.0,
            'total_late_minutes' => $totalLateMinutes,
            'total_early_logout_minutes' => $totalEarlyLogoutMinutes,
            'average_late_minutes' => $lateDaysCount > 0
                ? round($totalLateMinutes / $lateDaysCount, 1)
                : 0.0,
            'average_early_logout_minutes' => $earlyLogoutDaysCount > 0
                ? round($totalEarlyLogoutMinutes / $earlyLogoutDaysCount, 1)
                : 0.0,
            'details' => $details,
        ];
    }

    private function resolveSchedule(Employee $employee, Carbon $date): array
    {
        $timingSource = $this->attendanceClassificationService->shiftTimingForDate(
            trim((string) $employee->empId),
            $date->toDateString(),
            $employee
        );

        [$start, $end] = $this->extractTimingRange($timingSource);
        $start ??= self::DEFAULT_SHIFT_START;
        $end ??= self::DEFAULT_SHIFT_END;

        return [
            'start' => $start,
            'end' => $end,
            'duration_seconds' => $this->scheduleDurationSeconds($start, $end),
            'start_label' => $this->formatDisplayTime($start),
            'end_label' => $this->formatDisplayTime($end),
            'label' => $this->formatDisplayTime($start).' - '.$this->formatDisplayTime($end),
        ];
    }

    private function extractTimingRange(string $value): array
    {
        if ($value === '') {
            return [null, null];
        }

        preg_match_all(
            '/\d{1,2}(?::\d{2})?(?::\d{2})?\s*(?:[APap][Mm])?/',
            str_replace([' to ', ' TO ', '–', '—'], '-', $value),
            $matches
        );

        $times = collect($matches[0] ?? [])
            ->map(fn ($time): ?string => $this->normalizeTime($time))
            ->filter()
            ->values();

        $start = $times->get(0);
        $end = $times->get(1);

        return [$start, $end];
    }

    private function scheduleDurationSeconds(string $start, string $end): int
    {
        $startSeconds = $this->timeToSeconds($start);
        $endSeconds = $this->timeToSeconds($end);

        if ($endSeconds <= $startSeconds) {
            $endSeconds += 86400;
        }

        return $endSeconds - $startSeconds;
    }

    private function workedSeconds(?Attendance $appRecord, ?array $importedRecord, string $date): int
    {
        if ($importedRecord !== null) {
            $loggedSeconds = (int) ($importedRecord['logged_seconds'] ?? 0);

            if ($loggedSeconds > 0) {
                return $loggedSeconds;
            }

            return $this->timeRangeSeconds(
                $date,
                $importedRecord['first_login'] ?? null,
                $date,
                $importedRecord['last_logout'] ?? null
            );
        }

        if (! $appRecord instanceof Attendance) {
            return 0;
        }

        return $this->timeRangeSeconds(
            trim((string) $appRecord->check_in_date) ?: $date,
            $appRecord->check_in_time,
            trim((string) $appRecord->check_out_date) ?: $date,
            $appRecord->check_out_time
        );
    }

    private function timeRangeSeconds(
        string $startDate,
        ?string $startTime,
        string $endDate,
        ?string $endTime
    ): int {
        $normalizedStart = $this->normalizeTime($startTime);
        $normalizedEnd = $this->normalizeTime($endTime);

        if ($normalizedStart === null || $normalizedEnd === null) {
            return 0;
        }

        try {
            $start = Carbon::parse($startDate.' '.$normalizedStart);
            $end = Carbon::parse($endDate.' '.$normalizedEnd);

            if ($end->lte($start) && $startDate === $endDate) {
                $end->addDay();
            }

            return $end->gt($start) ? (int) $start->diffInSeconds($end) : 0;
        } catch (\Throwable) {
            return 0;
        }
    }

    private function normalizeTime(?string $value): ?string
    {
        $trimmed = trim((string) $value);

        if ($trimmed === '') {
            return null;
        }

        if (preg_match('/^\d{1,2}$/', $trimmed) === 1) {
            $hour = (int) $trimmed;

            if ($hour >= 0 && $hour <= 23) {
                return sprintf('%02d:00:00', $hour);
            }
        }

        $formats = ['H:i:s', 'H:i', 'g:i A', 'g:iA', 'h:i A', 'h:iA', 'g A', 'gA', 'h A', 'hA'];

        foreach ($formats as $format) {
            try {
                return Carbon::createFromFormat($format, strtoupper($trimmed))->format('H:i:s');
            } catch (\Throwable $exception) {
                continue;
            }
        }

        try {
            return Carbon::parse($trimmed)->format('H:i:s');
        } catch (\Throwable $exception) {
            return null;
        }
    }

    private function lateMinutes(?string $actualCheckInTime, string $expectedStartTime): int
    {
        $actual = $this->normalizeTime($actualCheckInTime);

        if ($actual === null) {
            return 0;
        }

        $actualSeconds = $this->timeToSeconds($actual);
        $expectedSeconds = $this->timeToSeconds($expectedStartTime);

        if ($expectedSeconds >= 43200 && $actualSeconds < 43200) {
            $actualSeconds += 86400;
        }

        $lateBoundarySeconds = $expectedSeconds + (self::GRACE_PERIOD_MINUTES * 60);

        if ($actualSeconds <= $lateBoundarySeconds) {
            return 0;
        }

        return (int) floor(($actualSeconds - $lateBoundarySeconds) / 60);
    }

    private function earlyLogoutMinutes(
        ?string $actualCheckOutTime,
        string $expectedStartTime,
        string $expectedEndTime
    ): int
    {
        $actual = $this->normalizeTime($actualCheckOutTime);

        if ($actual === null) {
            return 0;
        }

        $actualSeconds = $this->timeToSeconds($actual);
        $expectedStartSeconds = $this->timeToSeconds($expectedStartTime);
        $expectedSeconds = $this->timeToSeconds($expectedEndTime);

        if ($expectedSeconds <= $expectedStartSeconds) {
            $expectedSeconds += 86400;

            if ($actualSeconds < $expectedStartSeconds) {
                $actualSeconds += 86400;
            }
        }

        $earlyBoundarySeconds = $expectedSeconds - (self::GRACE_PERIOD_MINUTES * 60);

        if ($actualSeconds >= $earlyBoundarySeconds) {
            return 0;
        }

        return (int) floor(($earlyBoundarySeconds - $actualSeconds) / 60);
    }

    private function timeToSeconds(string $value): int
    {
        [$hours, $minutes, $seconds] = array_pad(array_map('intval', explode(':', $value)), 3, 0);

        return ($hours * 3600) + ($minutes * 60) + $seconds;
    }

    private function formatDisplayTime(?string $value): string
    {
        $normalized = $this->normalizeTime($value);

        if ($normalized === null) {
            return '--';
        }

        return Carbon::createFromFormat('H:i:s', $normalized)->format('h:i A');
    }

    private function dateSpanDays(Carbon $start, Carbon $end): int
    {
        return $start->copy()->startOfDay()->diffInDays($end->copy()->startOfDay()) + 1;
    }
}
