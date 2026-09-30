@extends('admin.layout.app')

@section('content')
    @include('admin.attendance.partials.styles')

    <style>
        .regularization-report-hero {
            border: 1px solid rgba(var(--admin-primary-color-rgb), 0.12);
            background: linear-gradient(135deg, rgba(var(--admin-primary-color-rgb), 0.1), var(--admin-surface-color) 62%);
        }

        .regularization-report-kpi,
        .regularization-report-table {
            height: 100%;
            border: 1px solid var(--admin-border-color);
            border-radius: 18px;
            background: var(--admin-surface-color);
        }

        .regularization-report-kpi .card-body,
        .regularization-report-table .card-body {
            padding: 1.1rem;
        }

        .regularization-report-kpi__label {
            color: var(--admin-muted-text-color);
            font-size: 0.82rem;
            margin-bottom: 0.35rem;
        }

        .regularization-report-kpi__value {
            color: var(--admin-text-color);
            font-size: 1.65rem;
            font-weight: 700;
            line-height: 1.15;
        }

        .regularization-report-rank {
            display: inline-flex;
            align-items: center;
            justify-content: center;
            width: 30px;
            height: 30px;
            border-radius: 50%;
            background: rgba(var(--admin-primary-color-rgb), 0.12);
            color: var(--admin-primary-color);
            font-weight: 700;
        }

        .regularization-report-count {
            display: inline-flex;
            min-width: 44px;
            justify-content: center;
            padding: 0.3rem 0.65rem;
            border-radius: 999px;
            color: #b42318;
            background: rgba(220, 53, 69, 0.12);
            font-weight: 700;
        }

        .regularization-report-table > .card-body > .table-responsive > .table {
            min-width: 900px;
        }

        .regularization-report-table thead th {
            white-space: nowrap;
            background: var(--admin-background-color, #f7f9fc);
        }

        .regularization-report-regularizer + .regularization-report-regularizer {
            margin-top: 0.25rem;
        }

        .regularization-report-details summary {
            cursor: pointer;
            color: var(--admin-primary-color);
            font-weight: 600;
        }

        .regularization-report-details .table {
            min-width: 620px;
            margin-top: 0.75rem;
        }
    </style>

    <div class="main-content attendance-page">
        <div class="page-breadcrumb d-none d-sm-flex align-items-center mb-3">
            <div class="breadcrumb-title pe-3">Regularization Report</div>
            <div class="ps-3">
                <nav aria-label="breadcrumb">
                    <ol class="breadcrumb mb-0 p-0">
                        <li class="breadcrumb-item"><a href="{{ route('admin-dashboard') }}"><i class="bx bx-home-alt"></i></a></li>
                        <li class="breadcrumb-item">Reports</li>
                        <li class="breadcrumb-item active" aria-current="page">Regularization Report</li>
                    </ol>
                </nav>
            </div>
        </div>

        <div class="card rounded-4 mb-3 regularization-report-hero">
            <div class="card-body">
                <div class="mb-3">
                    <h4 class="mb-1 attendance-title">Employee Regularization Report</h4>
                    <p class="mb-0 attendance-muted">
                        Employees are ranked from the most to the fewest regularized attendance days in the selected month.
                    </p>
                </div>

                <form method="get" action="{{ route('admin-attendance-regularization-report') }}" class="row g-3 align-items-end">
                    <div class="col-sm-6 col-md-4 col-xl-3">
                        <label class="form-label">Month</label>
                        <input type="month" name="month" value="{{ $filters['month'] }}" class="form-control" required>
                    </div>
                    <div class="col-sm-6 col-md-4 col-xl-3">
                        <label class="form-label">Location</label>
                        <select name="location" class="form-select">
                            <option value="all" @selected($filters['location'] === 'all')>All Locations</option>
                            <option value="ho" @selected($filters['location'] === 'ho')>Head Office</option>
                            @foreach ($filters['states'] as $state)
                                <option value="state:{{ $state }}" @selected($filters['location'] === 'state:'.$state)>{{ $state }}</option>
                            @endforeach
                        </select>
                    </div>
                    <div class="col-sm-6 col-md-3 col-xl-2">
                        <button type="submit" class="btn btn-primary w-100">Apply</button>
                    </div>
                </form>
            </div>
        </div>

        <div class="row g-3 mb-3">
            <div class="col-12 col-md-4">
                <div class="regularization-report-kpi"><div class="card-body">
                    <div class="regularization-report-kpi__label">Employees Regularized</div>
                    <div class="regularization-report-kpi__value">{{ $summary['employees'] }}</div>
                </div></div>
            </div>
            <div class="col-12 col-md-4">
                <div class="regularization-report-kpi"><div class="card-body">
                    <div class="regularization-report-kpi__label">Regularized Days</div>
                    <div class="regularization-report-kpi__value">{{ $summary['regularizations'] }}</div>
                </div></div>
            </div>
            <div class="col-12 col-md-4">
                <div class="regularization-report-kpi"><div class="card-body">
                    <div class="regularization-report-kpi__label">Regularized By</div>
                    <div class="regularization-report-kpi__value">{{ $summary['regularizers'] }}</div>
                </div></div>
            </div>
        </div>

        <div class="card rounded-4 mb-3 regularization-report-table">
            <div class="card-body">
                <div class="mb-3">
                    <h5 class="attendance-title mb-1">{{ $filters['month_label'] }} · {{ $filters['location_label'] }} Ranking</h5>
                    <p class="mb-0 attendance-muted">Each employee/date is counted once. Open details to see the date, status, source, and administrator.</p>
                </div>

                <div class="table-responsive">
                    <table class="table table-bordered table-hover align-middle mb-0">
                        <thead>
                            <tr>
                                <th>Rank</th>
                                <th>Employee</th>
                                <th>Location</th>
                                <th>Regularizations</th>
                                <th>Regularized By</th>
                                <th>Details</th>
                            </tr>
                        </thead>
                        <tbody>
                            @forelse ($rows as $row)
                                <tr>
                                    <td><span class="regularization-report-rank">{{ $loop->iteration }}</span></td>
                                    <td>
                                        <div class="fw-semibold">{{ $row['employee_name'] }}</div>
                                        <div class="small text-muted">{{ $row['emp_id'] }}{{ $row['designation'] ? ' | '.$row['designation'] : '' }}</div>
                                    </td>
                                    <td>
                                        @foreach ($row['locations'] as $location)
                                            <div class="regularization-report-regularizer">
                                                {{ $location['name'] }}
                                                <span class="badge text-bg-light">{{ $location['count'] }}</span>
                                            </div>
                                        @endforeach
                                    </td>
                                    <td><span class="regularization-report-count">{{ $row['regularization_count'] }}</span></td>
                                    <td>
                                        @foreach ($row['regularizers'] as $regularizer)
                                            <div class="regularization-report-regularizer">
                                                {{ $regularizer['name'] }}
                                                <span class="badge text-bg-light">{{ $regularizer['count'] }}</span>
                                            </div>
                                        @endforeach
                                    </td>
                                    <td>
                                        <details class="regularization-report-details">
                                            <summary>View {{ $row['regularization_count'] }} {{ \Illuminate\Support\Str::plural('entry', $row['regularization_count']) }}</summary>
                                            <div class="table-responsive">
                                                <table class="table table-sm table-bordered align-middle mb-0">
                                                    <thead>
                                                        <tr>
                                                            <th>Date</th>
                                                            <th>Status</th>
                                                            <th>Regularized By</th>
                                                            <th>Location</th>
                                                            <th>Source</th>
                                                        </tr>
                                                    </thead>
                                                    <tbody>
                                                        @foreach ($row['details'] as $detail)
                                                            <tr>
                                                                <td>{{ \Illuminate\Support\Carbon::parse($detail['attendance_date'])->format('d M Y') }}</td>
                                                                <td>{{ $detail['status_label'] }}</td>
                                                                <td>{{ $detail['regularized_by'] }}</td>
                                                                <td>{{ $detail['location_label'] }}</td>
                                                                <td>{{ $detail['source'] }}</td>
                                                            </tr>
                                                        @endforeach
                                                    </tbody>
                                                </table>
                                            </div>
                                        </details>
                                    </td>
                                </tr>
                            @empty
                                <tr>
                                    <td colspan="6" class="text-center text-muted py-4">No regularizations were found for {{ $filters['month_label'] }} in {{ $filters['location_label'] }}.</td>
                                </tr>
                            @endforelse
                        </tbody>
                    </table>
                </div>
            </div>
        </div>
    </div>
@endsection
