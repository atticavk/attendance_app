<?php

namespace App\Http\Controllers;

use App\Models\Employee;
use App\Models\IdCardSubmission;
use Illuminate\Database\QueryException;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Facades\URL;
use Illuminate\Validation\Rule;
use Illuminate\Validation\ValidationException;
use Symfony\Component\HttpFoundation\BinaryFileResponse;
use Throwable;

class EmployeeIdCardController extends Controller
{
    public function show(Request $request): JsonResponse
    {
        $employee = $request->user();
        abort_unless($employee instanceof Employee, 401);
        $eligible = $this->isEnabledFor($employee, $request);
        $submission = $eligible
            ? IdCardSubmission::query()->where('employee_id', $employee->id)->first()
            : null;

        return response()->json([
            // The existing app shows the menu only while "enabled" is true.
            // Disable it after submission so no mobile rebuild is required.
            'enabled' => $eligible && $submission === null,
            'submission' => $this->payload($submission),
        ]);
    }

    public function store(Request $request): JsonResponse
    {
        $employee = $request->user();
        abort_unless($employee instanceof Employee, 401);

        if (! $this->isEnabledFor($employee, $request)) {
            return response()->json([
                'message' => 'The ID Card feature is not enabled for this employee.',
            ], 403);
        }

        if (IdCardSubmission::query()->where('employee_id', $employee->id)->exists()) {
            return response()->json([
                'message' => 'An ID Card submission already exists for employee ID '.$employee->empId.'.',
            ], 409);
        }

        $data = $request->validate([
            'fullName' => ['required', 'string', 'max:255'],
            'designation' => ['required', 'string', 'max:255'],
            'dateOfBirth' => ['nullable', 'date', 'before_or_equal:today'],
            'bloodGroup' => ['required', Rule::in(['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'])],
            'phone' => ['required', 'regex:/^[0-9]{10}$/'],
            'emergencyContact' => ['required', 'regex:/^[0-9]{10}$/'],
            'homeAddress' => ['required', 'string', 'max:500'],
            'photo' => ['required', 'image', 'mimes:jpg,jpeg,png,webp', 'max:5120'],
        ]);

        $photoPath = $this->storePhoto($request);

        try {
            $submission = IdCardSubmission::query()->create([
                'employee_id' => $employee->id,
                'emp_id' => trim((string) $employee->empId),
                'full_name' => mb_strtoupper(trim($data['fullName'])),
                'designation' => trim($data['designation']),
                'date_of_birth' => $data['dateOfBirth'] ?? null,
                'blood_group' => $data['bloodGroup'],
                'phone' => $data['phone'],
                'emergency_contact' => $data['emergencyContact'],
                'home_address' => mb_strtoupper(trim($data['homeAddress'])),
                'photo_path' => $photoPath,
            ]);
        } catch (QueryException $exception) {
            Storage::disk('public')->delete($photoPath);
            if (in_array((int) ($exception->errorInfo[1] ?? 0), [1062, 19], true)) {
                return response()->json(['message' => 'An ID Card submission already exists for this employee ID.'], 409);
            }
            throw $exception;
        }

        return response()->json([
            'message' => 'ID Card submitted successfully.',
            'submission' => $this->payload($submission),
        ], 201);
    }

    public function photo(IdCardSubmission $submission): BinaryFileResponse
    {
        $disk = Storage::disk('public');

        abort_unless(
            is_string($submission->photo_path)
                && $submission->photo_path !== ''
                && $disk->exists($submission->photo_path),
            404
        );

        return response()->file($disk->path($submission->photo_path), [
            'Cache-Control' => 'private, max-age=3600',
            'X-Content-Type-Options' => 'nosniff',
        ]);
    }

    private function payload(?IdCardSubmission $submission): ?array
    {
        if (! $submission) {
            return null;
        }

        return [
            'id' => $submission->id,
            'empId' => $submission->emp_id,
            'fullName' => $submission->full_name,
            'designation' => $submission->designation,
            'dateOfBirth' => optional($submission->date_of_birth)->format('Y-m-d'),
            'bloodGroup' => $submission->blood_group,
            'phone' => $submission->phone,
            'emergencyContact' => $submission->emergency_contact,
            'homeAddress' => $submission->home_address,
            'photoUrl' => request()->getSchemeAndHttpHost()
                .URL::temporarySignedRoute(
                    'employee-id-card-photo',
                    now()->addDays(7),
                    ['submission' => $submission->id],
                    false
                ),
            'status' => $submission->status,
            'submittedAt' => optional($submission->created_at)->toIso8601String(),
        ];
    }

    private function isEnabledFor(Employee $employee, Request $request): bool
    {
        $access = strtolower(trim((string) config('id_card.employee_access', 'agpl000')));

        if ($access === 'all') {
            return true;
        }

        $prefix = strtoupper($access !== '' ? $access : 'agpl000');

        return str_starts_with($this->loginBranchId($employee, $request), $prefix);
    }

    private function loginBranchId(Employee $employee, Request $request): string
    {
        $token = $request->user()?->currentAccessToken();
        $abilities = is_array($token?->abilities) ? $token->abilities : [];

        foreach ($abilities as $ability) {
            $ability = (string) $ability;
            if (str_starts_with($ability, 'branch:')) {
                return strtoupper(trim(substr($ability, 7)));
            }
        }

        return strtoupper(trim((string) $employee->last_login_branch_id));
    }

    private function storePhoto(Request $request): string
    {
        try {
            $path = $request->file('photo')?->store('id-cards/photos', 'public');
        } catch (Throwable) {
            $path = false;
        }

        if (! is_string($path) || $path === '' || ! Storage::disk('public')->exists($path)) {
            throw ValidationException::withMessages([
                'photo' => 'The photo could not be saved. Please contact the administrator to check storage permissions.',
            ]);
        }

        return $path;
    }
}
