<?php

namespace App\Support;

use App\Models\Attendance;
use App\Models\AttendanceDayOverride;
use App\Models\AttendanceFraudReport;
use App\Models\Branch;
use App\Models\Employee;
use App\Models\EmployeeAdvanceRequest;
use App\Models\EmployeeAdvanceTransaction;
use App\Models\EmployeeBankDetailRequest;
use App\Models\EmployeeDetail;
use App\Models\EmployeeLocationPing;
use App\Models\EmployeeSalaryHold;
use App\Models\HoAttendanceImport;
use App\Models\HoAttendanceImportOverride;
use App\Models\LeaveRequest;
use App\Models\SiteVisitRequest;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;

class CsrManagerScope
{
    public static function apply(): void
    {
        Employee::addGlobalScope('csr_manager', function (Builder $query): void {
            self::scopeEligibleEmployeeDesignation($query);
        });

        Branch::addGlobalScope('csr_manager', function (Builder $query): void {
            $query->whereIn(
                $query->getModel()->qualifyColumn('branchId'),
                self::csrEmployeeQuery()->select('last_login_branch_id')
                    ->whereNotNull('last_login_branch_id')
            );
        });

        self::scopeByEmployeeCode(Attendance::class, 'empId');
        self::scopeByEmployeeCode(AttendanceDayOverride::class, 'emp_id');
        self::scopeByEmployeeCode(AttendanceFraudReport::class, 'emp_id');
        self::scopeByEmployeeCode(EmployeeAdvanceRequest::class, 'emp_id');
        self::scopeByEmployeeCode(EmployeeAdvanceTransaction::class, 'emp_id');
        self::scopeByEmployeeCode(EmployeeBankDetailRequest::class, 'emp_id');
        self::scopeByEmployeeCode(EmployeeSalaryHold::class, 'emp_id');
        self::scopeByEmployeeCode(HoAttendanceImport::class, 'emp_id');
        self::scopeByEmployeeCode(HoAttendanceImportOverride::class, 'emp_id');
        self::scopeByEmployeeCode(LeaveRequest::class, 'emp_id');
        self::scopeByEmployeeCode(SiteVisitRequest::class, 'emp_id');
        self::scopeByEmployeeCode(EmployeeLocationPing::class, 'emp_id');
        self::scopeByEmployeeCode(EmployeeDetail::class, 'employeeId');
    }

    public static function scopeEligibleEmployeeDesignation(Builder $query): Builder
    {
        $designation = $query->getModel()->qualifyColumn('designation');

        return $query->where(function (Builder $designationQuery) use ($designation): void {
            $designationQuery
                ->whereRaw("UPPER(COALESCE({$designation}, '')) LIKE ?", ['%CSR%'])
                ->orWhereRaw("UPPER(TRIM(COALESCE({$designation}, ''))) = ?", ['TELECALLER']);
        });
    }

    /**
     * @param  class-string<Model>  $modelClass
     */
    private static function scopeByEmployeeCode(string $modelClass, string $column): void
    {
        $modelClass::addGlobalScope('csr_manager', function (Builder $query) use ($column): void {
            $query->whereIn(
                $query->getModel()->qualifyColumn($column),
                self::csrEmployeeQuery()->select('empId')
            );
        });
    }

    private static function csrEmployeeQuery(): Builder
    {
        return self::scopeEligibleEmployeeDesignation(Employee::withoutGlobalScopes());
    }
}
