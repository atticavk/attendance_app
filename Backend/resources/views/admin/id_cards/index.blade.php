@extends('admin.layout.app')

@section('disable-admin-datatables', '1')

@section('content')
@php
    $serialStart = method_exists($submissions, 'firstItem')
        ? ($submissions->firstItem() ?? 1)
        : 1;
    $sortUrl = static function (string $column) use ($sort, $direction): string {
        $nextDirection = $sort === $column && $direction === 'asc' ? 'desc' : 'asc';

        return route('admin-id-cards-index', array_merge(
            request()->except(['page', 'sort', 'direction']),
            ['sort' => $column, 'direction' => $nextDirection]
        ));
    };
    $sortIcon = static function (string $column) use ($sort, $direction): string {
        if ($sort !== $column) {
            return 'unfold_more';
        }

        return $direction === 'asc' ? 'arrow_upward' : 'arrow_downward';
    };
@endphp
<style>
    .id-card-sort-link {
        display: inline-flex;
        align-items: center;
        gap: 0.2rem;
        color: inherit;
        font-weight: 600;
        text-decoration: none;
        white-space: nowrap;
    }
    .id-card-sort-link:hover { color: var(--bs-primary); }
    .id-card-sort-link .material-icons-outlined { font-size: 1rem; }
</style>
<div class="main-content">
    <div class="d-flex flex-wrap align-items-center justify-content-between gap-3 mb-3">
        <div><h4 class="mb-1">ID Card Submissions</h4><p class="text-muted mb-0">Employee ID-card applications submitted from the app.</p></div>
        <div class="d-flex flex-wrap gap-2">
            <a class="btn btn-outline-primary" href="{{ route('admin-id-cards-export') }}"><i class="material-icons-outlined align-middle">download</i> Download Submissions Excel</a>
            <a class="btn btn-outline-danger" href="{{ route('admin-id-cards-approved-pdf') }}" target="_blank" rel="noopener"><i class="material-icons-outlined align-middle">picture_as_pdf</i> Download Approved PDF</a>
            <a class="btn btn-outline-primary" href="{{ route('admin-id-cards-image-archive') }}"><i class="material-icons-outlined align-middle">folder_zip</i> Download All ID Cards ZIP</a>
            <a class="btn btn-primary" href="{{ route('admin-id-cards-create') }}"><i class="material-icons-outlined align-middle">add</i> Add ID Card</a>
        </div>
    </div>
    @if(session('success'))<div class="alert alert-success">{{ session('success') }}</div>@endif
    <div class="row g-3 mb-3">
        <div class="col-md-4">
            <div class="card h-100 rounded-4 border-0 shadow-sm">
                <div class="card-body d-flex align-items-center justify-content-between">
                    <div>
                        <p class="text-muted mb-1">Active Submissions</p>
                        <h2 class="mb-0">{{ number_format($totalSubmissions) }}</h2>
                    </div>
                    <span class="d-inline-flex align-items-center justify-content-center rounded-circle bg-primary-subtle text-primary" style="width:52px;height:52px">
                        <i class="material-icons-outlined">badge</i>
                    </span>
                </div>
            </div>
        </div>
        <div class="col-md-4">
            <a href="{{ route('admin-id-cards-index', ['record_state' => 'deleted']) }}" class="card h-100 rounded-4 border-0 shadow-sm text-start text-decoration-none text-body">
                <span class="card-body d-flex align-items-center justify-content-between">
                    <span><span class="text-muted d-block mb-1">Deleted Submissions</span><span class="h2 d-block mb-0">{{ number_format($deletedSubmissions) }}</span><small class="text-primary">Click to view deleted entries</small></span>
                    <span class="d-inline-flex align-items-center justify-content-center rounded-circle bg-danger-subtle text-danger" style="width:52px;height:52px"><i class="material-icons-outlined">delete</i></span>
                </span>
            </a>
        </div>
        <div class="col-md-4">
            <button type="button" class="card h-100 w-100 rounded-4 border-0 shadow-sm text-start bg-white"
                data-bs-toggle="modal" data-bs-target="#remainingSubmissionsModal"
                aria-label="View employees with pending ID card submissions">
                <span class="card-body d-flex align-items-center justify-content-between w-100">
                    <span>
                        <span class="text-muted d-block mb-1">Remaining Submissions</span>
                        <span class="h2 d-block mb-0">{{ number_format($remainingEmployees->count()) }}</span>
                        <small class="text-primary">Click to view employees</small>
                    </span>
                    <span class="d-inline-flex align-items-center justify-content-center rounded-circle bg-warning-subtle text-warning-emphasis" style="width:52px;height:52px">
                        <i class="material-icons-outlined">pending_actions</i>
                    </span>
                </span>
            </button>
        </div>
    </div>
    <div class="card rounded-4">
        <div class="card-body">
            @if($errors->any())<div class="alert alert-danger">{{ $errors->first() }}</div>@endif
            <form method="get" class="row g-2 align-items-end mb-3">
                <input type="hidden" name="sort" value="{{ $sort }}">
                <input type="hidden" name="direction" value="{{ $direction }}">
                <div class="col-md-3"><label class="form-label">Search</label><input class="form-control" type="search" name="q" value="{{ $search }}" placeholder="Employee ID, name or designation" autocomplete="off" spellcheck="false"></div>
                <div class="col-md-2"><label class="form-label">Status</label><select class="form-select" name="status"><option value="">All statuses</option><option value="pending" @selected($status === 'pending')>Pending</option><option value="approved" @selected($status === 'approved')>Approved</option></select></div>
                <div class="col-md-2"><label class="form-label">Entries</label><select class="form-select" name="record_state"><option value="active" @selected($recordState === 'active')>Active</option><option value="deleted" @selected($recordState === 'deleted')>Deleted</option><option value="all" @selected($recordState === 'all')>All</option></select></div>
                <div class="col-md-2"><label class="form-label">Results per page</label><select class="form-select" name="per_page">@foreach([10,20,50,100] as $size)<option value="{{ $size }}" @selected($perPage === $size)>{{ $size }}</option>@endforeach</select></div>
                <div class="col-auto"><button class="btn btn-primary">Search</button></div>
                <div class="col-auto"><a class="btn btn-outline-secondary" href="{{ route('admin-id-cards-index') }}">Clear</a></div>
            </form>
            <form method="post" action="{{ route('admin-id-cards-bulk') }}" id="idCardBulkForm" class="d-flex flex-wrap align-items-center gap-2 mb-3" @if($recordState === 'deleted') hidden @endif>
                @csrf
                <span class="text-muted small me-2"><strong data-selected-count>0</strong> selected</span>
                <button type="submit" name="action" value="approve" class="btn btn-success" data-bulk-action disabled>Approve Selected</button>
                <button type="submit" name="action" value="delete" class="btn btn-outline-danger" data-bulk-action data-confirm-delete disabled>Delete Selected</button>
            </form>
            <div class="table-responsive">
                <table class="table align-middle">
                    <thead><tr>
                        <th><input class="form-check-input" type="checkbox" data-select-all aria-label="Select all submissions on this page"></th>
                        <th>SL No</th>
                        @foreach([
                            'employee' => 'Employee',
                            'employee_id' => 'Employee ID',
                            'designation' => 'Designation',
                            'blood_group' => 'Blood',
                            'submitted' => 'Submitted',
                            'status' => 'Status',
                        ] as $column => $label)
                            <th aria-sort="{{ $sort === $column ? ($direction === 'asc' ? 'ascending' : 'descending') : 'none' }}">
                                <a class="id-card-sort-link" href="{{ $sortUrl($column) }}" title="Sort by {{ $label }}">
                                    <span>{{ $label }}</span>
                                    <i class="material-icons-outlined" aria-hidden="true">{{ $sortIcon($column) }}</i>
                                </a>
                            </th>
                        @endforeach
                        <th>Actions</th>
                    </tr></thead>
                    <tbody>
                    @forelse($submissions as $submission)
                        <tr>
                            <td>@unless($submission->trashed())<input class="form-check-input" type="checkbox" name="submission_ids[]" value="{{ $submission->id }}" form="idCardBulkForm" data-row-select aria-label="Select {{ $submission->full_name }}">@endunless</td>
                            <td>{{ $serialStart + $loop->index }}</td>
                            <td><div class="d-flex align-items-center gap-2">@unless($submission->trashed())<img src="{{ route('admin-id-cards-photo', ['submission' => $submission], false) }}" width="46" height="46" class="rounded-circle object-fit-cover" alt="" loading="lazy" decoding="async" fetchpriority="low">@endunless<strong>{{ $submission->full_name }}</strong></div></td>
                            <td>{{ $submission->emp_id }}</td><td>{{ $submission->designation }}</td><td>{{ $submission->blood_group }}</td>
                            <td>{{ $submission->created_at->format('d M Y') }}</td><td>@if($submission->trashed())<span class="badge bg-danger">Deleted {{ $submission->deleted_at->format('d M Y') }}</span>@else<span class="badge {{ $submission->status === 'approved' ? 'bg-success' : 'bg-warning text-dark' }}">{{ ucfirst($submission->status) }}</span>@endif</td>
                            <td>
                                <div class="d-flex flex-wrap gap-2">
                                    @if($submission->trashed())
                                    <form method="post" action="{{ route('admin-id-cards-restore', ['submission' => $submission->id]) }}" onsubmit="return confirm('Restore this ID Card submission?');">@csrf<button type="submit" class="btn btn-sm btn-outline-success">Restore</button></form>
                                    @else
                                    <a class="btn btn-sm btn-outline-primary" href="{{ route('admin-id-cards-edit', $submission) }}">Edit</a>
                                    <form method="post" action="{{ route('admin-id-cards-destroy', $submission) }}" onsubmit="return confirm('Delete this ID Card submission? The employee will be able to submit again.');">
                                        @csrf @method('DELETE')
                                        <button type="submit" class="btn btn-sm btn-outline-danger">Delete</button>
                                    </form>
                                    <a class="btn btn-sm btn-primary" href="{{ route('admin-id-cards-card', $submission) }}">View / Download ID Card</a>
                                    @endif
                                </div>
                            </td>
                        </tr>
                    @empty
                        <tr><td colspan="9" class="text-center text-muted py-4">No ID Card submissions found.</td></tr>
                    @endforelse
                    </tbody>
                </table>
            </div>
            @if (method_exists($submissions, 'links'))
                <div class="d-flex justify-content-center mt-3">
                    {{ $submissions->links('pagination::bootstrap-5') }}
                </div>
            @endif
        </div>
    </div>
</div>

<div class="modal fade" id="remainingSubmissionsModal" tabindex="-1"
    aria-labelledby="remainingSubmissionsModalLabel" aria-hidden="true">
    <div class="modal-dialog modal-xl modal-dialog-scrollable">
        <div class="modal-content rounded-4">
            <div class="modal-header">
                <div>
                    <h5 class="modal-title" id="remainingSubmissionsModalLabel">Remaining ID Card Submissions</h5>
                    <p class="text-muted small mb-0">Active HO employees who have not submitted ID-card details.</p>
                </div>
                <button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Close"></button>
            </div>
            <div class="modal-body">
                <div class="table-responsive">
                    <table class="table table-striped align-middle mb-0">
                        <thead>
                            <tr>
                                <th>Sl.No</th>
                                <th>Employee ID</th>
                                <th>Name</th>
                                <th>Designation</th>
                                <th>Contact</th>
                            </tr>
                        </thead>
                        <tbody>
                            @forelse($remainingEmployees as $employee)
                                <tr>
                                    <td>{{ $loop->iteration }}</td>
                                    <td>{{ $employee->empId }}</td>
                                    <td>{{ $employee->name }}</td>
                                    <td>{{ $employee->designation ?: '—' }}</td>
                                    <td>{{ $employee->contact ?: '—' }}</td>
                                </tr>
                            @empty
                                <tr>
                                    <td colspan="5" class="text-center text-muted py-4">
                                        All active HO employees have submitted their ID-card details.
                                    </td>
                                </tr>
                            @endforelse
                        </tbody>
                    </table>
                </div>
            </div>
            <div class="modal-footer">
                <a class="btn btn-outline-success" href="{{ route('admin-id-cards-remaining-csv') }}">
                    <i class="material-icons-outlined align-middle fs-6">download</i> Export CSV
                </a>
                <a class="btn btn-outline-danger" href="{{ route('admin-id-cards-remaining-pdf') }}" target="_blank" rel="noopener">
                    <i class="material-icons-outlined align-middle fs-6">picture_as_pdf</i> Export PDF
                </a>
                <button type="button" class="btn btn-secondary" data-bs-dismiss="modal">Close</button>
            </div>
        </div>
    </div>
</div>
<script>
document.addEventListener('DOMContentLoaded', function () {
    const selectAll = document.querySelector('[data-select-all]');
    const rowSelections = Array.from(document.querySelectorAll('[data-row-select]'));
    const actionButtons = Array.from(document.querySelectorAll('[data-bulk-action]'));
    const selectedCount = document.querySelector('[data-selected-count]');
    const bulkForm = document.getElementById('idCardBulkForm');

    function syncSelection() {
        const count = rowSelections.filter((checkbox) => checkbox.checked).length;
        if (selectedCount) selectedCount.textContent = String(count);
        actionButtons.forEach((button) => button.disabled = count === 0);
        if (selectAll) {
            selectAll.checked = rowSelections.length > 0 && count === rowSelections.length;
            selectAll.indeterminate = count > 0 && count < rowSelections.length;
        }
    }

    selectAll?.addEventListener('change', function () {
        rowSelections.forEach((checkbox) => checkbox.checked = selectAll.checked);
        syncSelection();
    });
    rowSelections.forEach((checkbox) => checkbox.addEventListener('change', syncSelection));
    bulkForm?.addEventListener('submit', function (event) {
        if (event.submitter?.matches('[data-confirm-delete]') && !confirm('Delete all selected ID Card submissions? Employees will be able to submit again.')) {
            event.preventDefault();
        }
    });
    syncSelection();
});
</script>
@endsection
