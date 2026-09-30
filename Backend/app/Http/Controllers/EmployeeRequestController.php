<?php

namespace App\Http\Controllers;

use App\Models\Attendance;
use App\Models\AttendanceDayOverride;
use App\Models\SalaryCalculationSetting;
use App\Models\Branch;
use App\Models\Employee;
use App\Models\EmployeeAdvanceRequest;
use App\Models\EmployeeAdvanceTransaction;
use App\Models\EmployeeBankDetailRequest;
use App\Models\EmployeeDetail;
use App\Models\LeaveRequest;
use App\Models\SiteVisitRequest;
use App\Services\AttendanceClassificationService;
use App\Support\AdvancePayrollWindow;
use App\Support\MayPfEligibility;
use App\Support\MayPfSecurityDeposit;
use App\Support\PfSalaryBreakdown;
use App\Support\SalaryProration;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\File;
use Illuminate\Support\Facades\Schema;
use Intervention\Image\Facades\Image;

class EmployeeRequestController extends Controller
{
    private const STATUS_FULL_DAY = 'full_day';

    private const STATUS_FULL_DAY_REMOTE = 'full_day_remote';

    private const STATUS_HALF_DAY = 'half_day';

    private const STATUS_SINGLE_PUNCH = 'single_punch';

    private const STATUS_ABSENT = 'absent';

    private const ATTENDANCE_RADIUS_METERS = 100.0;

    private const NIGHT_SHIFT_MONTHLY_WEEKOFF_DAYS = 4;

    public function __construct(
        private readonly AttendanceClassificationService $attendanceClassificationService
    ) {
    }

    public function salarySummary(Request $request): JsonResponse
    {
        $employee = $request->user();

        abort_unless($employee instanceof Employee, 401);

        $data = $request->validate([
            'month' => ['nullable', 'date_format:Y-m'],
        ]);

        $timezone = config('app.timezone', 'Asia/Kolkata');
        $today = Carbon::now($timezone);
        $selectedMonth = array_key_exists('month', $data) && $data['month']
            ? Carbon::createFromFormat('Y-m', $data['month'], $timezone)->startOfMonth()
            : $today->copy()->startOfMonth();

        if ($selectedMonth->gt($today->copy()->startOfMonth())) {
            return response()->json([
                'message' => 'Future salary months are not available.',
            ], 422);
        }

        $this->rememberSelectedSalaryMonth($request, $employee, $selectedMonth);

        $monthStart = $selectedMonth->copy()->startOfMonth();
        $monthEnd = $selectedMonth->copy()->endOfMonth();
        $todayDate = $today->copy()->startOfDay();
        $isCurrentMonth = $monthStart->isSameMonth($today);
        $summaryEndDate = $isCurrentMonth
            ? $today->copy()->subDay()->startOfDay()
            : $monthEnd->copy();
        $advanceWindow = $this->currentAdvancePayrollRange($monthStart, $today);
        $calendarDaysInMonth = $monthStart->daysInMonth;
        $salarySettings = SalaryCalculationSetting::configuration();
        $salaryDaysInMonth = $salarySettings['fixed_30_days'] ? 30 : $calendarDaysInMonth;
        $detail = $this->employeeDetail($employee);
        $isNightShiftEmployee = (bool) $employee->is_night_shift;
        $calendarDaysElapsed = $isCurrentMonth
            ? max(0, min($today->day - 1, $calendarDaysInMonth))
            : $calendarDaysInMonth;
        $records = Attendance::query()
            ->where('empId', $this->clean($employee->empId))
            ->whereBetween('check_in_date', [$monthStart->toDateString(), $monthEnd->toDateString()])
            ->orderBy('check_in_date')
            ->orderBy('id')
            ->get()
            ->keyBy(fn (Attendance $attendance): string => $attendance->check_in_date);
        $dayOverrides = AttendanceDayOverride::query()
            ->where('emp_id', $this->clean($employee->empId))
            ->whereBetween('attendance_date', [$monthStart->toDateString(), $monthEnd->toDateString()])
            ->get(['attendance_date', 'final_status'])
            ->keyBy(fn (AttendanceDayOverride $override): string => Carbon::parse($override->attendance_date)->toDateString());
        $firstRegularizedDate = $dayOverrides
            ->filter(fn (AttendanceDayOverride $override): bool => $this->isAttendanceStatus($override->final_status))
            ->keys()
            ->sort()
            ->first();
        $employmentStartDate = $this->salaryEmploymentStartDate($employee, $firstRegularizedDate);

        $fullDays = 0;
        $halfDays = 0;
        $absentDays = 0;
        $singlePunchDays = 0;
        $paidSundayDays = 0;
        $sundayLoggedDays = 0;
        $adminOverrideDays = 0;
        $anyPunches = 0;
        $regularizedDays = 0;
        $cursor = $monthStart->copy();

        while ($cursor->lte($summaryEndDate) && $cursor->lte($monthEnd)) {
            $date = $cursor->toDateString();
            $record = $records->get($date);
            $dayOverrideStatus = $this->clean($dayOverrides->get($date)?->final_status);
            $hasDayOverride = $this->isAttendanceStatus($dayOverrideStatus);
            $recordOverrideStatus = $this->clean($record?->attendance_status_override);
            $hasRecordOverride = $this->isAttendanceStatus($recordOverrideStatus);

            if ($employmentStartDate instanceof Carbon && $cursor->lt($employmentStartDate)) {
                $cursor->addDay();

                continue;
            }

            if ($record && (
                $this->clean($record->check_in_time) !== ''
                || $this->clean($record->check_out_time) !== ''
            )) {
                $anyPunches++;
            }

            if ($hasDayOverride || $hasRecordOverride) {
                $regularizedDays++;
            }

            if (! $isNightShiftEmployee && $cursor->isSunday() && $this->hasCompletedAttendance($record)) {
                $sundayLoggedDays++;
            }

            if (! $isNightShiftEmployee && $cursor->isSunday()) {
                // For the current month, only completed Sundays are credited.
                if (! $isCurrentMonth || $cursor->lt($todayDate)) {
                    $paidSundayDays++;
                }

                $cursor->addDay();

                continue;
            }

            $status = $this->effectiveAttendanceStatus($record, $dayOverrideStatus, $employee);

            if ($hasDayOverride) {
                $adminOverrideDays++;
            }

            if (in_array($status, [self::STATUS_FULL_DAY, self::STATUS_FULL_DAY_REMOTE], true)) {
                $fullDays++;
            } elseif ($status === self::STATUS_HALF_DAY) {
                $halfDays++;
            } elseif ($status === self::STATUS_SINGLE_PUNCH) {
                $singlePunchDays++;
            } elseif ($status === self::STATUS_ABSENT) {
                $absentDays++;
            }

            $cursor->addDay();
        }

        if ($isNightShiftEmployee && $absentDays > 0) {
            $nightShiftWeekOffDays = min($absentDays, self::NIGHT_SHIFT_MONTHLY_WEEKOFF_DAYS);
            $absentDays -= $nightShiftWeekOffDays;
            $paidSundayDays += $nightShiftWeekOffDays;
        }

        $payableDays = $paidSundayDays + $fullDays + ($halfDays * 0.5);
        $hasSalaryActivity = $anyPunches > 0 || $regularizedDays > 0;

        if (! $hasSalaryActivity) {
            $payableDays = 0.0;
        }
        $salary = is_numeric($detail?->salary) ? (float) $detail->salary : (is_numeric($employee->salary) ? (float) $employee->salary : 0.0);
        $uanNumber = $this->salaryUanNumber($employee, $detail);
        $pf = 0.0;
        $securityDeposit = MayPfSecurityDeposit::amountFor(
            $monthStart,
            $employee->empId,
            $uanNumber,
            $employee->designation ?: $detail?->designation,
            $employee->pf_eligible,
            $employee->pfsecuritydeposit
        );

        if (! $hasSalaryActivity) {
            $pf = 0.0;
            $securityDeposit = 0.0;
        }
        $advance = (float) EmployeeAdvanceTransaction::query()
            ->where('employee_id', $employee->id)
            ->whereBetween('advance_date', [
                $advanceWindow['start']->toDateString(),
                $advanceWindow['end']->toDateString(),
            ])
            ->sum('amount');
        $salaryPerDay = SalaryProration::dailyRate($salary, $salaryDaysInMonth);
        $grossPayable = $hasSalaryActivity
            ? SalaryProration::grossPayable($salary, $salaryDaysInMonth, $payableDays)
            : 0.0;
        $netPayable = $hasSalaryActivity ? round($grossPayable - $advance - $securityDeposit) : 0.0;

        if ($salarySettings['pf_enabled'] && $hasSalaryActivity && MayPfEligibility::isEligible($monthStart, $employee->empId, $uanNumber, $employee->pf_eligible)) {
            $breakdown = PfSalaryBreakdown::forReportRow([
                'emp_id' => $this->clean($employee->empId),
                'state' => $this->salaryState($employee, $detail),
                'designation' => $employee->designation ?: $detail?->designation,
                'salary_days_in_month' => $salaryDaysInMonth,
                'credited_days' => $payableDays,
                'gross_payable_salary' => $grossPayable,
                'advance' => $advance,
                'security_deposit' => $securityDeposit,
            ]);
            $pf = $breakdown['ee_pf'];
            $netPayable = $breakdown['take_home_salary'];
        }

        return response()->json([
            'summary' => [
                'month' => $monthStart->format('Y-m'),
                'monthLabel' => $monthStart->format('F Y'),
                'salary' => $salary,
                'salaryPerDay' => $salaryPerDay,
                'salaryDaysInMonth' => $salaryDaysInMonth,
                'advance' => $advance,
                'pf' => $pf,
                'securityDeposit' => $securityDeposit,
                'fullDays' => $fullDays,
                'halfDays' => $halfDays,
                'singlePunchDays' => $singlePunchDays,
                'absentDays' => $absentDays,
                'paidSundayDays' => $paidSundayDays,
                'sundayLoggedDays' => $sundayLoggedDays,
                'adminOverrideDays' => $adminOverrideDays,
                'regularizedDays' => $regularizedDays,
                'payableDays' => $payableDays,
                'grossPayableSalary' => $grossPayable,
                'netPayableSalary' => $netPayable,
                'daysElapsed' => $calendarDaysElapsed,
                'daysInMonth' => $calendarDaysInMonth,
            ],
        ]);
    }

    public function advanceRequests(Request $request): JsonResponse
    {
        $employee = $request->user();

        abort_unless($employee instanceof Employee, 401);

        if ((bool) $employee->is_outsourced) {
            return response()->json([
                'message' => 'Outsourced employees cannot request advance from the app.',
            ], 422);
        }

        $data = $request->validate([
            'month' => ['nullable', 'date_format:Y-m'],
        ]);
        $selectedMonth = isset($data['month'])
            ? Carbon::createFromFormat('!Y-m', $data['month'], config('app.timezone', 'Asia/Kolkata'))->startOfMonth()
            : $this->rememberedSalaryMonth($request, $employee);
        $advanceWindow = AdvancePayrollWindow::forPayrollMonth($selectedMonth);

        $this->rememberSelectedSalaryMonth($request, $employee, $selectedMonth);

        $requests = EmployeeAdvanceRequest::query()
            ->where('employee_id', $employee->id)
            ->whereBetween('request_date', [
                $advanceWindow['start']->toDateString(),
                $advanceWindow['end']->toDateString(),
            ])
            ->orderByDesc('id')
            ->get()
            ->map(fn (EmployeeAdvanceRequest $advanceRequest): array => $this->advanceRequestPayload($advanceRequest))
            ->values();

        return response()->json([
            'advanceRequests' => $requests,
        ]);
    }

    public function submitAdvanceRequest(Request $request): JsonResponse
    {
        $employee = $request->user();

        abort_unless($employee instanceof Employee, 401);

        if ((bool) $employee->is_outsourced) {
            return response()->json([
                'message' => 'Outsourced employees cannot request advance from the app.',
            ], 422);
        }

        $data = $request->validate([
            'amount' => ['required', 'numeric', 'gt:0', 'max:5000'],
            'request_note' => ['nullable', 'string', 'max:2000'],
        ]);

        $hasVerifiedRequest = EmployeeAdvanceRequest::query()
            ->where('employee_id', $employee->id)
            ->where('status', EmployeeAdvanceRequest::STATUS_VERIFIED)
            ->exists();

        if ($hasVerifiedRequest) {
            return response()->json([
                'message' => 'Active advance request already exists.',
            ], 422);
        }

        $hasPendingRequest = EmployeeAdvanceRequest::query()
            ->where('employee_id', $employee->id)
            ->where('status', EmployeeAdvanceRequest::STATUS_PENDING)
            ->exists();

        if ($hasPendingRequest) {
            return response()->json([
                'message' => 'An advance request is already pending verification.',
            ], 422);
        }

        $requestDate = Carbon::now(config('app.timezone', 'Asia/Kolkata'))->startOfDay();

        $advanceRequest = EmployeeAdvanceRequest::query()->create([
            'employee_id' => $employee->id,
            'emp_id' => $this->clean($employee->empId),
            'request_date' => $requestDate->toDateString(),
            'amount' => round((float) $data['amount'], 2),
            'request_note' => trim((string) ($data['request_note'] ?? '')) ?: null,
            'status' => EmployeeAdvanceRequest::STATUS_PENDING,
        ]);

        return response()->json([
            'message' => 'Advance request submitted successfully. It will be applied after admin verification.',
            'advanceRequest' => $this->advanceRequestPayload($advanceRequest),
        ], 201);
    }

    public function submitLeave(Request $request): JsonResponse
    {
        $employee = $request->user();

        abort_unless($employee instanceof Employee, 401);

        $data = $request->validate([
            'leave_date' => ['required', 'date'],
            'reason' => ['required', 'string', 'min:5', 'max:2000'],
        ]);

        $leaveDate = Carbon::parse($data['leave_date'], config('app.timezone', 'Asia/Kolkata'))->toDateString();

        $leaveRequest = LeaveRequest::query()->create([
            'employee_id' => $employee->id,
            'emp_id' => $this->clean($employee->empId),
            'leave_date' => $leaveDate,
            'reason' => trim($data['reason']),
            'status' => 'pending',
        ]);

        return response()->json([
            'message' => 'Leave request submitted successfully.',
            'leaveRequest' => $this->leaveRequestPayload($leaveRequest),
        ], 201);
    }

    public function leaveRequests(Request $request): JsonResponse
    {
        $employee = $request->user();

        abort_unless($employee instanceof Employee, 401);

        $leaveRequests = LeaveRequest::query()
            ->where('employee_id', $employee->id)
            ->orderByDesc('leave_date')
            ->orderByDesc('id')
            ->get()
            ->map(fn (LeaveRequest $leaveRequest): array => $this->leaveRequestPayload($leaveRequest))
            ->values();

        return response()->json([
            'leaveRequests' => $leaveRequests,
        ]);
    }

    public function requestBankDetailEdit(Request $request): JsonResponse
    {
        $employee = $request->user();

        abort_unless($employee instanceof Employee, 401);

        $data = $request->validate([
            'request_note' => ['nullable', 'string', 'max:2000'],
        ]);

        $latestRequest = $this->latestBankDetailRequest($employee);

        $latestRequestStatus = strtolower($this->clean($latestRequest?->status));

        if ($latestRequest && in_array($latestRequestStatus, [
            EmployeeBankDetailRequest::STATUS_PENDING,
            EmployeeBankDetailRequest::STATUS_APPROVED,
            EmployeeBankDetailRequest::STATUS_SUBMITTED,
        ], true)) {
            return response()->json([
                'message' => 'A bank detail request is already in progress.',
            ], 422);
        }

        $requestRecord = EmployeeBankDetailRequest::query()->create([
            'employee_id' => $employee->id,
            'emp_id' => $this->clean($employee->empId),
            'status' => EmployeeBankDetailRequest::STATUS_PENDING,
            'request_note' => trim((string) ($data['request_note'] ?? '')) ?: null,
        ]);

        return response()->json([
            'message' => 'Bank detail edit request submitted successfully.',
            'request' => $this->bankDetailRequestPayload($requestRecord),
        ], 201);
    }

    public function submitInitialUanNumber(Request $request): JsonResponse
    {
        $employee = $request->user();

        abort_unless($employee instanceof Employee, 401);

        $data = $request->validate([
            'uan_number' => ['required', 'string', 'regex:/^\d{12}$/'],
        ]);

        $detail = $this->employeeDetail($employee);

        if ($this->clean($detail?->uanNumber) !== '') {
            return response()->json([
                'message' => 'UAN number is already saved. Please request edit access to change it.',
            ], 422);
        }

        $detail ??= new EmployeeDetail();
        $now = Carbon::now(config('app.timezone', 'Asia/Kolkata'));

        $detail->employeeId = $this->clean($employee->empId);
        $detail->empName = $this->clean($detail->empName) ?: $this->clean($employee->name);
        $detail->designation = $this->clean($detail->designation) ?: $this->clean($employee->designation);
        $detail->bankName = $this->clean($detail->bankName);
        $detail->bankAcNo = $this->clean($detail->bankAcNo);
        $detail->ifscCode = $this->clean($detail->ifscCode);
        $detail->passbookDoc = $this->clean($detail->passbookDoc);
        $detail->salary = is_numeric($detail->salary) ? $detail->salary : (is_numeric($employee->salary) ? $employee->salary : 0);
        $detail->branchId = $this->clean($detail->branchId) ?: $this->latestAttendanceBranchId($employee);
        $detail->status = $this->clean($detail->status) ?: 'Active';
        $detail->accountVerified = $this->clean($detail->accountVerified) ?: 'Pending';
        $detail->date = $detail->date ?: $now->toDateString();
        $detail->time = $detail->time ?: $now->format('H:i:s');
        $detail->totalWorkingDays = is_numeric($detail->totalWorkingDays) ? $detail->totalWorkingDays : 0;
        $detail->absentDays = is_numeric($detail->absentDays) ? $detail->absentDays : 0;
        $detail->presentDays = is_numeric($detail->presentDays) ? $detail->presentDays : 0;
        $detail->penalty = is_numeric($detail->penalty) ? $detail->penalty : 0;
        $detail->advanceSalary = is_numeric($detail->advanceSalary) ? $detail->advanceSalary : 0;
        $detail->finalSalary = is_numeric($detail->finalSalary) ? $detail->finalSalary : 0;
        $detail->salaryPaymentStatus = $this->clean($detail->salaryPaymentStatus);
        $detail->salaryPaidBy = $this->clean($detail->salaryPaidBy);
        $detail->salaryBankName = $this->clean($detail->salaryBankName);
        $detail->salaryProcessingBy = $this->clean($detail->salaryProcessingBy);
        $detail->salaryProcessingUser = $this->clean($detail->salaryProcessingUser);
        $detail->aadhaarNo = $this->clean($detail->aadhaarNo);
        $detail->uanNumber = trim((string) $data['uan_number']);
        $detail->pfAmount = is_numeric($detail->pfAmount) ? $detail->pfAmount : (is_numeric($employee->pf) ? $employee->pf : 0);
        $detail->save();

        return response()->json([
            'message' => 'UAN number saved successfully.',
        ]);
    }

    public function submitBankDetails(Request $request): JsonResponse
    {
        $employee = $request->user();

        abort_unless($employee instanceof Employee, 401);

        $requestRecord = $this->latestBankDetailRequest($employee);

        $requestStatus = strtolower($this->clean($requestRecord?->status));

        if (! $requestRecord || $requestStatus !== EmployeeBankDetailRequest::STATUS_APPROVED) {
            return response()->json([
                'message' => 'Your bank details can be edited only after admin approval.',
            ], 422);
        }

        $data = $request->validate([
            'account_name' => ['required', 'string', 'max:150'],
            'bank_name' => ['required', 'string', 'max:150'],
            'bank_account_number' => ['required', 'string', 'max:50'],
            'ifsc_code' => ['required', 'string', 'max:30'],
            'uan_number' => ['nullable', 'string', 'regex:/^\d{12}$/'],
            'request_note' => ['nullable', 'string', 'max:2000'],
            'passbook_doc' => ['nullable', 'image', 'max:5120'],
        ]);

        $requestedPassbookDoc = $requestRecord->requested_passbook_doc;

        if ($request->hasFile('passbook_doc')) {
            $requestedPassbookDoc = $this->storePassbookDocument(
                $request->file('passbook_doc'),
                $employee,
                $requestedPassbookDoc
            );
        }

        $requestRecord->update([
            'status' => EmployeeBankDetailRequest::STATUS_SUBMITTED,
            'request_note' => trim((string) ($data['request_note'] ?? $requestRecord->request_note)) ?: $requestRecord->request_note,
            'requested_emp_name' => trim((string) $data['account_name']),
            'requested_bank_name' => trim((string) $data['bank_name']),
            'requested_bank_ac_no' => trim((string) $data['bank_account_number']),
            'requested_ifsc_code' => trim((string) $data['ifsc_code']),
            'requested_uan_number' => trim((string) ($data['uan_number'] ?? '')),
            'requested_passbook_doc' => $requestedPassbookDoc,
            'submitted_at' => now(),
        ]);

        return response()->json([
            'message' => 'Updated bank details submitted and are pending verification.',
            'request' => $this->bankDetailRequestPayload($requestRecord->fresh()),
        ]);
    }

    public function submitSiteVisit(Request $request): JsonResponse
    {
        $employee = $request->user();

        abort_unless($employee instanceof Employee, 401);

        $data = $request->validate([
            'visit_date' => ['required', 'date_format:Y-m-d'],
            'site_location' => ['required', 'string', 'max:255'],
            'latitude' => ['required', 'numeric'],
            'longitude' => ['required', 'numeric'],
            'reason' => ['required', 'string', 'min:5', 'max:2000'],
            'approved_by' => ['required', 'string', 'max:255'],
            'photo' => ['required', 'image', 'max:5120'],
        ]);

        $today = Carbon::today(config('app.timezone', 'Asia/Kolkata'));
        $visitDate = Carbon::createFromFormat(
            'Y-m-d',
            $data['visit_date'],
            config('app.timezone', 'Asia/Kolkata')
        )->startOfDay();

        if (! $visitDate->equalTo($today)) {
            return response()->json([
                'message' => 'Work visits can be submitted only for the current day.',
            ], 422);
        }

        $branchId = $this->resolveBranchId($employee, $request);
        $branchValidation = $this->ensureOutsideAssignedBranch(
            $branchId,
            (float) $data['latitude'],
            (float) $data['longitude']
        );

        if ($branchValidation instanceof JsonResponse) {
            return $branchValidation;
        }

        $siteVisit = SiteVisitRequest::query()->create([
            'employee_id' => $employee->id,
            'emp_id' => $this->clean($employee->empId),
            'visit_date' => $today->toDateString(),
            'site_location' => trim($data['site_location']),
            'latitude' => (float) $data['latitude'],
            'longitude' => (float) $data['longitude'],
            'photo_path' => $this->storeSiteVisitPhoto($request->file('photo'), $employee),
            'reason' => trim($data['reason']),
            'approved_by' => trim($data['approved_by']),
            'status' => 'pending',
        ]);

        return response()->json([
            'message' => 'Site visit request submitted successfully.',
            'siteVisitRequest' => $this->siteVisitPayload($siteVisit),
        ], 201);
    }

    public function siteVisitRequests(Request $request): JsonResponse
    {
        $employee = $request->user();

        abort_unless($employee instanceof Employee, 401);

        $this->syncSiteVisitRequestOwnership($employee);

        $siteVisitRequests = $this->siteVisitRequestsQuery($employee)
            ->orderByDesc('visit_date')
            ->orderByDesc('id')
            ->get()
            ->map(fn (SiteVisitRequest $siteVisitRequest): array => $this->siteVisitPayload($siteVisitRequest))
            ->values();

        return response()->json([
            'siteVisitRequests' => $siteVisitRequests,
        ]);
    }

    private function siteVisitRequestsQuery(Employee $employee)
    {
        $empId = $this->clean($employee->empId);

        return SiteVisitRequest::query()
            ->where(function ($query) use ($employee, $empId): void {
                $query->where('employee_id', $employee->id);

                if ($empId !== '') {
                    $query->orWhereRaw('TRIM(emp_id) = ?', [$empId]);
                }
            });
    }

    private function syncSiteVisitRequestOwnership(Employee $employee): void
    {
        $empId = $this->clean($employee->empId);

        if ($empId === '') {
            return;
        }

        SiteVisitRequest::query()
            ->whereRaw('TRIM(emp_id) = ?', [$empId])
            ->where('employee_id', '!=', $employee->id)
            ->update(['employee_id' => $employee->id]);
    }

    private function leaveRequestPayload(LeaveRequest $leaveRequest): array
    {
        return [
            'id' => $leaveRequest->id,
            'empId' => $this->clean($leaveRequest->emp_id),
            'leaveDate' => optional($leaveRequest->leave_date)->toDateString(),
            'reason' => trim((string) $leaveRequest->reason),
            'status' => trim((string) $leaveRequest->status),
            'appliedAt' => optional($leaveRequest->created_at)?->toIso8601String(),
        ];
    }

    private function advanceRequestPayload(EmployeeAdvanceRequest $advanceRequest): array
    {
        return [
            'id' => $advanceRequest->id,
            'empId' => $this->clean($advanceRequest->emp_id),
            'requestDate' => optional($advanceRequest->request_date)->toDateString(),
            'amount' => is_numeric($advanceRequest->amount) ? round((float) $advanceRequest->amount, 2) : 0.0,
            'requestNote' => $this->clean($advanceRequest->request_note),
            'status' => $this->clean($advanceRequest->status),
            'adminNote' => $this->clean($advanceRequest->admin_note),
            'verifiedAt' => $advanceRequest->verified_at?->toIso8601String(),
            'rejectedAt' => $advanceRequest->rejected_at?->toIso8601String(),
            'createdAt' => $advanceRequest->created_at?->toIso8601String(),
        ];
    }

    private function currentAdvancePayrollRange(Carbon $payrollMonth, Carbon $date): array
    {
        return AdvancePayrollWindow::currentOpenWindowForPayrollMonth($payrollMonth, $date);
    }

    private function rememberSelectedSalaryMonth(Request $request, Employee $employee, Carbon $month): void
    {
        Cache::put(
            $this->selectedSalaryMonthCacheKey($request, $employee),
            $month->format('Y-m'),
            now()->addMinutes(15)
        );
    }

    private function rememberedSalaryMonth(Request $request, Employee $employee): Carbon
    {
        $value = Cache::get($this->selectedSalaryMonthCacheKey($request, $employee));

        if (is_string($value) && preg_match('/^\d{4}-\d{2}$/', $value) === 1) {
            return Carbon::createFromFormat('!Y-m', $value, config('app.timezone', 'Asia/Kolkata'))->startOfMonth();
        }

        return Carbon::now(config('app.timezone', 'Asia/Kolkata'))->startOfMonth();
    }

    private function selectedSalaryMonthCacheKey(Request $request, Employee $employee): string
    {
        $accessToken = $employee->currentAccessToken();
        $tokenId = is_numeric($accessToken?->id ?? null) ? (string) $accessToken->id : '';
        $bearerToken = trim((string) $request->bearerToken());
        $tokenKey = $tokenId !== ''
            ? 'token-'.$tokenId
            : ($bearerToken !== '' ? 'bearer-'.hash('sha256', $bearerToken) : 'employee-'.$employee->id);

        return 'salary:selected-month:'.$tokenKey;
    }

    private function siteVisitPayload(SiteVisitRequest $siteVisitRequest): array
    {
        return [
            'id' => $siteVisitRequest->id,
            'empId' => $this->clean($siteVisitRequest->emp_id),
            'visitDate' => optional($siteVisitRequest->visit_date)->toDateString(),
            'siteLocation' => trim((string) $siteVisitRequest->site_location),
            'latitude' => $siteVisitRequest->latitude,
            'longitude' => $siteVisitRequest->longitude,
            'reason' => trim((string) $siteVisitRequest->reason),
            'approvedBy' => trim((string) $siteVisitRequest->approved_by),
            'photoUrl' => $this->resolvePhotoUrl($siteVisitRequest->photo_path),
            'status' => trim((string) $siteVisitRequest->status),
            'appliedAt' => optional($siteVisitRequest->created_at)?->toIso8601String(),
        ];
    }

    private function effectiveAttendanceStatus(
        ?Attendance $attendance,
        ?string $dayOverrideStatus = null,
        ?Employee $employee = null
    ): string
    {
        $dayOverrideStatus = $this->clean($dayOverrideStatus);

        if ($this->isAttendanceStatus($dayOverrideStatus)) {
            return $dayOverrideStatus;
        }

        if (! $attendance) {
            return self::STATUS_ABSENT;
        }

        $override = $this->clean($attendance->attendance_status_override);

        if ($this->isAttendanceStatus($override)) {
            return $override;
        }

        return $this->attendanceClassificationService->calculatedStatus($attendance, $employee);
    }

    private function hasCompletedAttendance(?Attendance $attendance): bool
    {
        return $attendance !== null
            && $this->clean($attendance->check_in_date) !== ''
            && $this->clean($attendance->check_in_time) !== ''
            && $this->clean($attendance->check_out_date) !== ''
            && $this->clean($attendance->check_out_time) !== '';
    }

    private function isAttendanceStatus(?string $status): bool
    {
        return in_array($this->clean($status), [
            self::STATUS_FULL_DAY,
            self::STATUS_FULL_DAY_REMOTE,
            self::STATUS_HALF_DAY,
            self::STATUS_SINGLE_PUNCH,
            self::STATUS_ABSENT,
        ], true);
    }

    private function resolveBranchId(Employee $employee, ?Request $request = null): string
    {
        if ($request) {
            $token = $request->user()?->currentAccessToken();
            $abilities = is_array($token?->abilities) ? $token->abilities : [];

            foreach ($abilities as $ability) {
                if (str_starts_with((string) $ability, 'branch:')) {
                    return $this->clean(substr((string) $ability, 7));
                }
            }
        }

        $attendance = Attendance::query()
            ->where('empId', $this->clean($employee->empId))
            ->latest('id')
            ->first(['check_in_branch_id', 'check_out_branch_id']);

        if (! $attendance) {
            return '';
        }

        return $this->clean($attendance->check_out_branch_id) ?: $this->clean($attendance->check_in_branch_id);
    }

    private function ensureOutsideAssignedBranch(
        string $branchId,
        float $latitude,
        float $longitude
    ): ?JsonResponse {
        $branch = $this->findBranch($branchId);

        if (! $branch) {
            return null;
        }

        $branchLatitude = $this->parseCoordinate($branch->latitude);
        $branchLongitude = $this->parseCoordinate($branch->longitude);

        if ($branchLatitude === null || $branchLongitude === null) {
            return null;
        }

        $distanceMeters = round(
            $this->calculateDistanceMeters(
                $latitude,
                $longitude,
                $branchLatitude,
                $branchLongitude
            ),
            2
        );

        if ($distanceMeters <= self::ATTENDANCE_RADIUS_METERS) {
            return response()->json([
                'message' => sprintf(
                    'Site visit requests are only allowed away from your assigned branch. You are currently within %s of %s.',
                    $this->formatDistance(self::ATTENDANCE_RADIUS_METERS),
                    $this->clean((string) ($branch->branchName ?: $branch->branchId))
                ),
            ], 422);
        }

        return null;
    }

    private function storeSiteVisitPhoto($image, Employee $employee): string
    {
        $directory = public_path('storage/SiteVisitImage');

        if (! File::exists($directory)) {
            File::makeDirectory($directory, 0777, true);
        }

        $extension = strtolower($image->getClientOriginalExtension() ?: 'jpg');
        $empId = preg_replace('/[^A-Za-z0-9_-]+/', '-', $this->clean($employee->empId));
        $filename = sprintf(
            'site_visit_%s_%s_%s.%s',
            $empId ?: 'employee',
            Carbon::now(config('app.timezone', 'Asia/Kolkata'))->format('YmdHis'),
            bin2hex(random_bytes(4)),
            $extension
        );

        Image::make($image)
            ->resize(256, 256)
            ->save($directory.'/'.$filename);

        return 'storage/SiteVisitImage/'.$filename;
    }

    private function resolvePhotoUrl(?string $path): string
    {
        $trimmed = trim((string) $path);

        if ($trimmed === '') {
            return '';
        }

        if (preg_match('/^https?:\/\//i', $trimmed) === 1) {
            return $trimmed;
        }

        $normalizedPath = ltrim($trimmed, '/');

        if (str_starts_with($normalizedPath, 'public/')) {
            $normalizedPath = substr($normalizedPath, 7);
        }

        return function_exists('project_asset')
            ? \project_asset($normalizedPath)
            : asset($normalizedPath);
    }

    private function employeeDetail(Employee $employee): ?EmployeeDetail
    {
        return EmployeeDetail::query()
            ->whereRaw('TRIM(employeeId) = ?', [$this->clean($employee->empId)])
            ->orderByDesc('id')
            ->first();
    }

    private function salaryUanNumber(Employee $employee, ?EmployeeDetail $detail): string
    {
        $uanNumber = preg_replace('/\D+/', '', (string) $detail?->uanNumber) ?? '';

        if ($uanNumber !== '') {
            return $uanNumber;
        }

        if (! Schema::hasTable('employee_bank_detail_requests')) {
            return MayPfEligibility::uanForEmployee($employee->empId);
        }

        $requestUan = EmployeeBankDetailRequest::query()
            ->where('employee_id', $employee->id)
            ->whereIn('status', [
                EmployeeBankDetailRequest::STATUS_SUBMITTED,
                EmployeeBankDetailRequest::STATUS_VERIFIED,
            ])
            ->whereNotNull('requested_uan_number')
            ->where('requested_uan_number', '<>', '')
            ->latest('id')
            ->value('requested_uan_number');
        $uanNumber = preg_replace('/\D+/', '', (string) $requestUan) ?? '';

        return $uanNumber !== ''
            ? $uanNumber
            : MayPfEligibility::uanForEmployee($employee->empId);
    }

    private function salaryState(Employee $employee, ?EmployeeDetail $detail): string
    {
        if (! Schema::hasTable('wp_branches_database')) {
            return '';
        }

        $branchId = $this->clean($detail?->branchId) ?: $this->latestAttendanceBranchId($employee);

        return $this->clean(
            Branch::query()
                ->whereRaw('TRIM(branchId) = ?', [$branchId])
                ->value('state')
        );
    }

    private function salaryEmploymentStartDate(Employee $employee, ?string $firstRegularizedDate = null): ?Carbon
    {
        $doj = $this->clean($employee->doj);

        if ($doj !== '') {
            try {
                return Carbon::parse($doj, config('app.timezone', 'Asia/Kolkata'))->startOfDay();
            } catch (\Throwable) {
                // Fall back to the first recorded attendance date.
            }
        }

        $firstAttendanceDate = Attendance::query()
            ->whereRaw('TRIM(empId) = ?', [$this->clean($employee->empId)])
            ->min('check_in_date');

        $firstActivityDate = collect([$firstAttendanceDate, $firstRegularizedDate])
            ->map(fn ($date): string => $this->clean($date))
            ->filter()
            ->sort()
            ->first();

        return $this->clean($firstActivityDate) !== ''
            ? Carbon::parse($firstActivityDate, config('app.timezone', 'Asia/Kolkata'))->startOfDay()
            : null;
    }

    private function latestBankDetailRequest(Employee $employee): ?EmployeeBankDetailRequest
    {
        return EmployeeBankDetailRequest::query()
            ->where('employee_id', $employee->id)
            ->latest('id')
            ->first();
    }

    private function latestAttendanceBranchId(Employee $employee): string
    {
        $attendance = Attendance::query()
            ->whereRaw('TRIM(empId) = ?', [$this->clean($employee->empId)])
            ->latest('id')
            ->first(['check_in_branch_id', 'check_out_branch_id']);

        if (! $attendance) {
            return '';
        }

        return $this->clean($attendance->check_out_branch_id ?: $attendance->check_in_branch_id);
    }

    private function bankDetailRequestPayload(EmployeeBankDetailRequest $requestRecord): array
    {
        return [
            'id' => $requestRecord->id,
            'status' => $this->clean($requestRecord->status),
            'requestNote' => $this->clean($requestRecord->request_note),
            'adminNote' => $this->clean($requestRecord->admin_note),
            'accountName' => $this->clean($requestRecord->requested_emp_name),
            'bankName' => $this->clean($requestRecord->requested_bank_name),
            'bankAccountNumber' => $this->clean($requestRecord->requested_bank_ac_no),
            'ifscCode' => $this->clean($requestRecord->requested_ifsc_code),
            'uanNumber' => $this->clean($requestRecord->requested_uan_number),
            'passbookDocUrl' => $this->resolvePhotoUrl($requestRecord->requested_passbook_doc),
            'submittedAt' => $requestRecord->submitted_at?->toIso8601String(),
        ];
    }

    private function storePassbookDocument($image, Employee $employee, ?string $existingPath): string
    {
        $directory = public_path('storage/PassbookDocs');

        if (! File::exists($directory)) {
            File::makeDirectory($directory, 0777, true);
        }

        $currentPath = trim((string) $existingPath);

        if ($currentPath !== '') {
            $absoluteExistingPath = public_path(ltrim($currentPath, '/'));

            if (File::exists($absoluteExistingPath)) {
                File::delete($absoluteExistingPath);
            }
        }

        $extension = strtolower($image->getClientOriginalExtension() ?: 'jpg');
        $empId = preg_replace('/[^A-Za-z0-9_-]+/', '-', $this->clean($employee->empId));
        $filename = sprintf(
            'passbook_%s_%s_%s.%s',
            $empId ?: 'employee',
            Carbon::now(config('app.timezone', 'Asia/Kolkata'))->format('YmdHis'),
            bin2hex(random_bytes(4)),
            $extension
        );

        Image::make($image)
            ->orientate()
            ->resize(1400, null, function ($constraint): void {
                $constraint->aspectRatio();
                $constraint->upsize();
            })
            ->save($directory.'/'.$filename);

        return 'storage/PassbookDocs/'.$filename;
    }

    private function findBranch(?string $branchId): ?Branch
    {
        $branchId = $this->clean($branchId);

        if ($branchId === '') {
            return null;
        }

        return Branch::query()
            ->select(['id', 'branchId', 'branchName', 'latitude', 'longitude'])
            ->whereRaw('TRIM(branchId) = ?', [$branchId])
            ->first();
    }

    private function parseCoordinate($value): ?float
    {
        $trimmed = trim((string) $value);

        if ($trimmed === '' || ! is_numeric($trimmed)) {
            return null;
        }

        return (float) $trimmed;
    }

    private function calculateDistanceMeters(
        float $fromLatitude,
        float $fromLongitude,
        float $toLatitude,
        float $toLongitude
    ): float {
        $earthRadius = 6371000.0;
        $latitudeDelta = deg2rad($toLatitude - $fromLatitude);
        $longitudeDelta = deg2rad($toLongitude - $fromLongitude);
        $fromLatitudeRad = deg2rad($fromLatitude);
        $toLatitudeRad = deg2rad($toLatitude);

        $a = sin($latitudeDelta / 2) ** 2 +
            cos($fromLatitudeRad) * cos($toLatitudeRad) *
            sin($longitudeDelta / 2) ** 2;
        $c = 2 * atan2(sqrt($a), sqrt(1 - $a));

        return $earthRadius * $c;
    }

    private function formatDistance(float $distanceMeters): string
    {
        if ($distanceMeters >= 1000) {
            return number_format($distanceMeters / 1000, 2).' km';
        }

        return round($distanceMeters).' m';
    }

    private function clean(?string $value): string
    {
        return trim((string) $value);
    }
}
