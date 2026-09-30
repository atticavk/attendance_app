<?php

namespace App\Http\Controllers\Admin;

use App\Http\Controllers\Controller;
use App\Models\Employee;
use App\Models\IdCardSubmission;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Storage;
use Illuminate\Validation\Rule;
use Illuminate\Validation\ValidationException;
use Illuminate\View\View;
use Symfony\Component\HttpFoundation\BinaryFileResponse;
use Symfony\Component\HttpFoundation\StreamedResponse;
use Throwable;

class IdCardController extends Controller
{
    public function index(Request $request): View
    {
        $search = trim((string) $request->input('q'));
        $status = trim((string) $request->input('status'));
        $status = in_array($status, ['pending', 'approved'], true) ? $status : '';
        $recordState = trim((string) $request->input('record_state', 'active'));
        $recordState = in_array($recordState, ['active', 'deleted', 'all'], true) ? $recordState : 'active';
        $perPage = (int) $request->integer('per_page', 20);
        $perPage = in_array($perPage, [10, 20, 50, 100], true) ? $perPage : 20;
        $sortableColumns = [
            'employee' => 'full_name',
            'employee_id' => 'emp_id',
            'designation' => 'designation',
            'blood_group' => 'blood_group',
            'submitted' => 'created_at',
            'status' => 'status',
        ];
        $sort = trim((string) $request->input('sort'));
        $sort = array_key_exists($sort, $sortableColumns) ? $sort : 'submitted';
        $direction = strtolower(trim((string) $request->input('direction')));
        $direction = in_array($direction, ['asc', 'desc'], true) ? $direction : 'desc';
        $totalSubmissions = IdCardSubmission::query()->count();
        $deletedSubmissions = IdCardSubmission::onlyTrashed()->count();
        $remainingEmployees = $this->remainingEmployees();
        $submissions = IdCardSubmission::query()
            ->when($recordState === 'deleted', fn ($query) => $query->onlyTrashed())
            ->when($recordState === 'all', fn ($query) => $query->withTrashed())
            ->when($search !== '', fn ($query) => $query->where(function ($query) use ($search): void {
                $query->where('emp_id', 'like', "%{$search}%")
                    ->orWhere('full_name', 'like', "%{$search}%")
                    ->orWhere('designation', 'like', "%{$search}%");
            }))
            ->when($status !== '', fn ($query) => $query->where('status', $status))
            ->orderBy($sortableColumns[$sort], $direction)
            ->orderByDesc('id')
            ->paginate($perPage)
            ->withQueryString();

        return view('admin.id_cards.index', compact(
            'submissions',
            'search',
            'status',
            'recordState',
            'perPage',
            'sort',
            'direction',
            'totalSubmissions',
            'deletedSubmissions',
            'remainingEmployees'
        ));
    }

    public function create(): View
    {
        $employees = Employee::query()->orderBy('name')->get(['id', 'empId', 'name', 'designation', 'contact', 'address']);
        return view('admin.id_cards.create', compact('employees'));
    }

    public function store(Request $request): RedirectResponse
    {
        $data = $request->validate([
            'employee_id' => ['required', 'exists:employee,id', Rule::unique('id_card_submissions', 'employee_id')->whereNull('deleted_at')],
            'full_name' => ['required', 'string', 'max:255'],
            'designation' => ['required', 'string', 'max:255'],
            'blood_group' => ['required', Rule::in(['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'])],
            'phone' => ['required', 'regex:/^[0-9]{10}$/'],
            'emergency_contact' => ['required', 'regex:/^[0-9]{10}$/'],
            'home_address' => ['required', 'string', 'max:500'],
            'photo' => ['required', 'image', 'mimes:jpg,jpeg,png,webp', 'max:5120'],
        ]);
        $employee = Employee::query()->findOrFail($data['employee_id']);
        $path = $this->storePhoto($request);
        unset($data['photo']);

        IdCardSubmission::query()->create([
            ...$data,
            'emp_id' => trim((string) $employee->empId),
            'photo_path' => $path,
        ]);

        return redirect()->route('admin-id-cards-index')->with('success', 'ID Card submission added.');
    }

    public function card(IdCardSubmission $submission): View
    {
        return view('admin.id_cards.card', compact('submission'));
    }

    public function printCard(IdCardSubmission $submission): View
    {
        return view('admin.id_cards.print', compact('submission'));
    }

    public function edit(IdCardSubmission $submission): View
    {
        return view('admin.id_cards.edit', compact('submission'));
    }

    public function update(Request $request, IdCardSubmission $submission): RedirectResponse
    {
        $data = $request->validate([
            'full_name' => ['required', 'string', 'max:255'],
            'designation' => ['required', 'string', 'max:255'],
            'blood_group' => ['required', Rule::in(['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'])],
            'phone' => ['required', 'regex:/^[0-9]{10}$/'],
            'emergency_contact' => ['required', 'regex:/^[0-9]{10}$/'],
            'home_address' => ['required', 'string', 'max:500'],
            'status' => ['required', Rule::in(['pending', 'approved'])],
            'admin_notes' => ['nullable', 'string', 'max:2000'],
            'photo' => ['nullable', 'image', 'mimes:jpg,jpeg,png,webp', 'max:5120'],
        ]);

        if ($request->hasFile('photo')) {
            $oldPhotoPath = $submission->photo_path;
            $data['photo_path'] = $this->storePhoto($request);
        }
        unset($data['photo']);

        $submission->update($data);
        if (isset($oldPhotoPath)) {
            Storage::disk('public')->delete($oldPhotoPath);
        }

        return redirect()->route('admin-id-cards-index')->with('success', 'ID Card submission updated.');
    }

    public function destroy(IdCardSubmission $submission): RedirectResponse
    {
        $submission->delete();

        return redirect()->route('admin-id-cards-index')->with('success', 'ID Card submission deleted.');
    }

    public function restore(int $submission): RedirectResponse
    {
        $deletedSubmission = IdCardSubmission::onlyTrashed()->findOrFail($submission);

        if (IdCardSubmission::query()->where('employee_id', $deletedSubmission->employee_id)->exists()) {
            return back()->withErrors(['restore' => 'This employee already has an active ID Card submission.']);
        }

        $deletedSubmission->restore();

        return back()->with('success', 'ID Card submission restored.');
    }

    public function bulk(Request $request): RedirectResponse
    {
        $data = $request->validate([
            'submission_ids' => ['required', 'array', 'min:1'],
            'submission_ids.*' => ['integer', 'distinct', 'exists:id_card_submissions,id'],
            'action' => ['required', Rule::in(['approve', 'delete'])],
        ], [
            'submission_ids.required' => 'Select at least one ID Card submission.',
            'submission_ids.min' => 'Select at least one ID Card submission.',
        ]);

        $submissions = IdCardSubmission::query()
            ->whereIn('id', $data['submission_ids'])
            ->get();

        if ($data['action'] === 'approve') {
            IdCardSubmission::query()
                ->whereIn('id', $submissions->pluck('id'))
                ->update(['status' => 'approved', 'updated_at' => now()]);

            return back()->with('success', $submissions->count().' ID Card submission(s) approved.');
        }

        DB::transaction(function () use ($submissions): void {
            IdCardSubmission::query()->whereIn('id', $submissions->pluck('id'))->delete();
        });

        return back()->with('success', $submissions->count().' ID Card submission(s) deleted.');
    }

    public function export(): StreamedResponse
    {
        return response()->streamDownload(function (): void {
            $output = fopen('php://output', 'wb');
            fputcsv($output, ['Employee ID', 'Name', 'Designation', 'DOB', 'Blood Group', 'Phone', 'Emergency Contact', 'Address', 'Status', 'Submitted']);
            IdCardSubmission::query()->latest()->chunk(500, function ($rows) use ($output): void {
                foreach ($rows as $row) {
                    fputcsv($output, [$row->emp_id, $row->full_name, $row->designation, optional($row->date_of_birth)->format('Y-m-d'), $row->blood_group, $row->phone, $row->emergency_contact, $row->home_address, $row->status, $row->created_at]);
                }
            });
            fclose($output);
        }, 'id-card-submissions-'.now()->format('Y-m-d').'.csv', ['Content-Type' => 'text/csv']);
    }

    public function remainingCsv(): StreamedResponse
    {
        $employees = $this->remainingEmployees();

        return response()->streamDownload(function () use ($employees): void {
            $output = fopen('php://output', 'wb');
            fputcsv($output, ['Sl.No', 'Employee ID', 'Name', 'Designation', 'Contact']);

            foreach ($employees as $index => $employee) {
                fputcsv($output, [
                    $index + 1,
                    $employee->empId,
                    $employee->name,
                    $employee->designation,
                    $employee->contact,
                ]);
            }

            fclose($output);
        }, 'remaining-id-card-submissions-'.now()->format('Y-m-d').'.csv', [
            'Content-Type' => 'text/csv',
        ]);
    }

    public function remainingPdf(): View
    {
        return view('admin.id_cards.remaining_pdf', [
            'employees' => $this->remainingEmployees(),
        ]);
    }

    public function approvedPdf(): View
    {
        return view('admin.id_cards.approved_pdf', [
            'submissions' => IdCardSubmission::query()
                ->where('status', 'approved')
                ->orderBy('emp_id')
                ->get(),
        ]);
    }

    public function imageArchive(): View
    {
        $submissions = IdCardSubmission::query()->orderBy('emp_id')->get();

        return view('admin.id_cards.image_archive', compact('submissions'));
    }

    public function html2canvasScript(): BinaryFileResponse
    {
        return $this->javascriptAsset('html2canvas.min.js');
    }

    public function jsZipScript(): BinaryFileResponse
    {
        return $this->javascriptAsset('jszip.min.js');
    }

    public function cardLogo(): BinaryFileResponse
    {
        $path = public_path('id-card-assets/attica-logo-official.png');
        abort_unless(is_file($path), 404);

        return response()->file($path, [
            'Content-Type' => 'image/png',
            'Cache-Control' => 'private, max-age=86400',
            'X-Content-Type-Options' => 'nosniff',
        ]);
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

    private function javascriptAsset(string $filename): BinaryFileResponse
    {
        $path = public_path('id-card-assets/'.$filename);
        abort_unless(is_file($path), 404);

        return response()->file($path, [
            'Content-Type' => 'application/javascript; charset=UTF-8',
            'Cache-Control' => 'private, max-age=3600',
            'X-Content-Type-Options' => 'nosniff',
        ]);
    }

    private function remainingEmployees(): Collection
    {
        return Employee::query()
            ->whereRaw("UPPER(TRIM(last_login_branch_id)) = 'AGPL000'")
            ->where(function ($query): void {
                $query->whereNull('status')
                    ->orWhereRaw("LOWER(TRIM(status)) <> 'inactive'");
            })
            ->whereNotIn('id', IdCardSubmission::query()->select('employee_id'))
            ->orderBy('name')
            ->get(['id', 'empId', 'name', 'designation', 'contact']);
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
                'photo' => 'The photo could not be saved. Check storage permissions and try again.',
            ]);
        }

        return $path;
    }
}
