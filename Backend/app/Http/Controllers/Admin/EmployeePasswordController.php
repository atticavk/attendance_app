<?php

namespace App\Http\Controllers\Admin;

use App\Http\Controllers\Controller;
use App\Models\Employee;
use App\Models\EmployeeAppCredential;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Hash;
use Illuminate\View\View;

class EmployeePasswordController extends Controller
{
    public function index(Request $request): View
    {
        $search = trim((string) $request->query('search'));
        $employees = Employee::query()
            ->when($search !== '', function ($query) use ($search): void {
                $query->where(function ($employeeQuery) use ($search): void {
                    $employeeQuery->where('empId', 'like', '%'.$search.'%')
                        ->orWhere('name', 'like', '%'.$search.'%');
                });
            })
            ->orderBy('empId')
            ->paginate(25)
            ->withQueryString();

        $credentialCounts = EmployeeAppCredential::query()
            ->whereIn('employee_id', $employees->getCollection()->pluck('id'))
            ->selectRaw('employee_id, COUNT(*) as credential_count')
            ->groupBy('employee_id')
            ->pluck('credential_count', 'employee_id');

        return view('admin.employee.reset_password', compact('employees', 'credentialCounts', 'search'));
    }

    public function update(Request $request, Employee $employee): RedirectResponse
    {
        $data = $request->validate([
            'password' => ['required', 'string', 'min:6', 'max:255', 'confirmed'],
        ]);

        $credentials = EmployeeAppCredential::query()
            ->where('employee_id', $employee->id)
            ->orWhereRaw('TRIM(emp_id) = ?', [trim((string) $employee->empId)])
            ->get();

        if ($credentials->isEmpty()) {
            return back()->withErrors([
                'password' => 'This employee has not created an app login yet. They must set a password on their first login.',
            ]);
        }

        $passwordHash = Hash::make($data['password']);
        $now = now(config('app.timezone', 'Asia/Kolkata'));

        foreach ($credentials as $credential) {
            $credential->forceFill([
                'employee_id' => $employee->id,
                'emp_id' => trim((string) $employee->empId),
                'password_hash' => $passwordHash,
                'password_set_at' => $now,
            ])->save();
        }

        $employee->tokens()->delete();

        return back()->with('status', 'Password reset successfully for '.$employee->name.'.');
    }
}
