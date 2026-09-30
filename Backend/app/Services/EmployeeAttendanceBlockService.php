<?php

namespace App\Services;

use App\Models\Attendance;
use App\Models\Employee;
use App\Models\LeaveRequest;
use App\Models\SiteVisitRequest;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;

class EmployeeAttendanceBlockService
{
    private const JOINING_GRACE_DAYS = 7;

    public function syncEligibleEmployees(?Carbon $today = null): int
    {
        $today = ($today ?? now(config('app.timezone', 'Asia/Kolkata')))->copy()->startOfDay();
        $employees = Employee::query()
            ->where(function ($query): void {
                $query->where('status', 'Active')
                    ->orWhereNull('status')
                    ->orWhereRaw("TRIM(status) = ''");
            })
            ->select(['id', 'empId', 'status', 'doj', 'attendance_unblocked_on'])
            ->get();

        if ($employees->isEmpty()) {
            return 0;
        }

        $absenceMap = $this->consecutiveAbsentDaysForEmployees($employees, $today);
        $employeeIdsToBlock = [];

        foreach ($employees as $employee) {
            if ($this->isWithinJoiningGracePeriod($employee, $today)) {
                continue;
            }

            if ($this->cleanDate($employee->attendance_unblocked_on) === $today->toDateString()) {
                continue;
            }

            if (($absenceMap[(int) $employee->id] ?? 0) < 3) {
                continue;
            }

            $employeeIdsToBlock[] = (int) $employee->id;
        }

        if ($employeeIdsToBlock === []) {
            return 0;
        }

        return Employee::query()
            ->whereIn('id', $employeeIdsToBlock)
            ->update([
                'status' => 'Blocked',
                'attendance_blocked_on' => $today->toDateString(),
                'attendance_unblocked_on' => null,
            ]);
    }

    public function syncEmployee(Employee $employee, ?Carbon $today = null): bool
    {
        $today = ($today ?? now(config('app.timezone', 'Asia/Kolkata')))->copy()->startOfDay();
        $currentStatus = trim((string) $employee->status);

        if ($currentStatus === 'Blocked') {
            return false;
        }

        if (! $this->isAttendanceBlockEligibleStatus($currentStatus)) {
            return false;
        }

        if ($this->isWithinJoiningGracePeriod($employee, $today)) {
            return false;
        }

        if ($this->cleanDate($employee->attendance_unblocked_on) === $today->toDateString()) {
            return false;
        }

        if (($this->consecutiveAbsentDaysForEmployees(collect([$employee]), $today)[(int) $employee->id] ?? 0) < 3) {
            return false;
        }

        $employee->status = 'Blocked';
        $employee->attendance_blocked_on = $today->toDateString();
        $employee->attendance_unblocked_on = null;
        $employee->save();

        return true;
    }

    public function isBlocked(Employee $employee, ?Carbon $today = null): bool
    {
        $today = ($today ?? now(config('app.timezone', 'Asia/Kolkata')))->copy()->startOfDay();

        if (trim((string) $employee->status) === 'Blocked') {
            return true;
        }

        if ($this->isWithinJoiningGracePeriod($employee, $today)) {
            return false;
        }

        if ($this->cleanDate($employee->attendance_unblocked_on) === $today->toDateString()) {
            return false;
        }

        return ($this->consecutiveAbsentDaysForEmployees(collect([$employee]), $today)[(int) $employee->id] ?? 0) >= 3;
    }

    public function consecutiveAbsentDays(Employee $employee, ?Carbon $today = null): int
    {
        $today = ($today ?? now(config('app.timezone', 'Asia/Kolkata')))->copy()->startOfDay();
        return $this->consecutiveAbsentDaysForEmployees(collect([$employee]), $today)[(int) $employee->id] ?? 0;
    }

    public function consecutiveAbsentDaysForEmployees(Collection $employees, ?Carbon $today = null): array
    {
        $today = ($today ?? now(config('app.timezone', 'Asia/Kolkata')))->copy()->startOfDay();
        $employeeIdByEmpId = [];

        foreach ($employees as $employee) {
            $empId = trim((string) $employee->empId);

            if ($empId !== '') {
                $employeeIdByEmpId[$empId] = (int) $employee->id;
            }
        }

        if ($employeeIdByEmpId === []) {
            return [];
        }

        $empIds = array_keys($employeeIdByEmpId);
        $latestAttendanceByEmpId = Attendance::query()
            ->selectRaw('empId, MAX(check_in_date) as latest_attendance_date')
            ->whereIn('empId', $empIds)
            ->groupBy('empId')
            ->pluck('latest_attendance_date', 'empId')
            ->all();

        $datesToCheck = $this->previousWorkingDates($today, 3);
        $employeeIds = $employees->pluck('id')->map(fn ($id): int => (int) $id)->all();
        $excusedDatesByEmployeeId = [];

        $leaveRequests = LeaveRequest::query()
            ->whereIn('leave_date', $datesToCheck->all())
            ->where(function ($query) use ($employeeIds, $empIds): void {
                $query->whereIn('employee_id', $employeeIds)
                    ->orWhereIn('emp_id', $empIds);
            })
            ->get(['employee_id', 'emp_id', 'leave_date']);

        foreach ($leaveRequests as $leaveRequest) {
            $employeeId = (int) $leaveRequest->employee_id;
            if (! in_array($employeeId, $employeeIds, true)) {
                $employeeId = $employeeIdByEmpId[trim((string) $leaveRequest->emp_id)] ?? 0;
            }
            if ($employeeId > 0) {
                $excusedDatesByEmployeeId[$employeeId][Carbon::parse($leaveRequest->leave_date)->toDateString()] = true;
            }
        }

        $workVisitRequests = SiteVisitRequest::query()
            ->whereIn('visit_date', $datesToCheck->all())
            ->where(function ($query) use ($employeeIds, $empIds): void {
                $query->whereIn('employee_id', $employeeIds)
                    ->orWhereIn('emp_id', $empIds);
            })
            ->get(['employee_id', 'emp_id', 'visit_date']);

        foreach ($workVisitRequests as $workVisitRequest) {
            $employeeId = (int) $workVisitRequest->employee_id;
            if (! in_array($employeeId, $employeeIds, true)) {
                $employeeId = $employeeIdByEmpId[trim((string) $workVisitRequest->emp_id)] ?? 0;
            }
            if ($employeeId > 0) {
                $excusedDatesByEmployeeId[$employeeId][Carbon::parse($workVisitRequest->visit_date)->toDateString()] = true;
            }
        }

        $presentDatesByEmpId = [];
        $attendanceRows = Attendance::query()
            ->whereIn('empId', $empIds)
            ->whereIn('check_in_date', $datesToCheck->all())
            ->where(function ($query) {
                $query->whereNull('attendance_status_override')
                    ->orWhere('attendance_status_override', '!=', 'absent');
            })
            ->get(['empId', 'check_in_date']);

        foreach ($attendanceRows as $attendance) {
            $presentDatesByEmpId[trim((string) $attendance->empId)][Carbon::parse($attendance->check_in_date)->toDateString()] = true;
        }

        $absenceMap = [];

        foreach ($employees as $employee) {
            $empId = trim((string) $employee->empId);
            $employeeId = (int) $employee->id;

            if ($this->isWithinJoiningGracePeriod($employee, $today)) {
                $absenceMap[$employeeId] = 0;
                continue;
            }

            if ($empId === '' || ! array_key_exists($empId, $latestAttendanceByEmpId)) {
                $absenceMap[$employeeId] = 0;
                continue;
            }

            $presentDates = $presentDatesByEmpId[$empId] ?? [];
            $excusedDates = $excusedDatesByEmployeeId[$employeeId] ?? [];
            $blockingStartsOn = $this->attendanceBlockingStartsOn($employee);
            $eligibleDates = $blockingStartsOn
                ? $datesToCheck->filter(
                    fn (string $date): bool => Carbon::parse($date)->gte($blockingStartsOn)
                )->values()
                : $datesToCheck;

            if ($eligibleDates->count() < 3) {
                $absenceMap[$employeeId] = 0;
                continue;
            }

            $absenceMap[$employeeId] = $eligibleDates
                ->contains(fn (string $date): bool => isset($presentDates[$date]) || isset($excusedDates[$date]))
                ? 0
                : $eligibleDates->count();
        }

        return $absenceMap;
    }

    private function previousWorkingDates(Carbon $today, int $days): Collection
    {
        $dates = collect();
        $cursor = $today->copy()->subDay();

        while ($dates->count() < $days) {
            if (! $cursor->isSunday()) {
                $dates->push($cursor->toDateString());
            }

            $cursor->subDay();
        }

        return $dates;
    }

    private function cleanDate($value): string
    {
        return trim((string) $value);
    }

    private function isWithinJoiningGracePeriod(Employee $employee, Carbon $today): bool
    {
        $blockingStartsOn = $this->attendanceBlockingStartsOn($employee);

        return $blockingStartsOn instanceof Carbon && $today->lt($blockingStartsOn);
    }

    private function attendanceBlockingStartsOn(Employee $employee): ?Carbon
    {
        $dateOfJoining = $this->cleanDate($employee->doj);

        if ($dateOfJoining === '') {
            return null;
        }

        try {
            return Carbon::parse($dateOfJoining, config('app.timezone', 'Asia/Kolkata'))
                ->startOfDay()
                ->addDays(self::JOINING_GRACE_DAYS);
        } catch (\Throwable) {
            return null;
        }
    }

    private function isAttendanceBlockEligibleStatus(string $status): bool
    {
        return $status === '' || $status === 'Active';
    }
}
