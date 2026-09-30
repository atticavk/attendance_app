<?php

namespace App\Http\Controllers\Admin;

use App\Http\Controllers\Controller;
use App\Models\Employee;
use Illuminate\Http\Request;
use Illuminate\Support\Carbon;
use Illuminate\View\View;

class BirthdayCalendarController extends Controller
{
    public function index(Request $request): View
    {
        $now = now();
        $month = (int) $request->integer('month', $now->month);
        $month = max(1, min(12, $month));
        $year = (int) $request->integer('year', $now->year);
        $year = max(1900, min(2100, $year));

        $birthdays = Employee::query()
            ->select(['id', 'empId', 'name', 'designation', 'date_of_birth'])
            ->whereNotNull('date_of_birth')
            ->whereRaw('LOWER(TRIM(status)) = ?', ['active'])
            ->whereMonth('date_of_birth', $month)
            ->orderByRaw('DAY(date_of_birth), name')
            ->get()
            ->groupBy(fn (Employee $employee): int => Carbon::parse($employee->date_of_birth)->day);

        return view('admin.employee.birthday_calendar', compact('month', 'year', 'birthdays'));
    }
}
