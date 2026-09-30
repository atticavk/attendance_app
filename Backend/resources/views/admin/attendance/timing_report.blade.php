@extends('admin.layout.app')

@section('content')
    @include('admin.attendance.partials.styles')
    @php
        $formatDuration = static function (int|float $seconds): string {
            $seconds = max((int) round($seconds), 0);
            $hours = intdiv($seconds, 3600);
            $minutes = intdiv($seconds % 3600, 60);

            return sprintf('%dh %02dm', $hours, $minutes);
        };
        $formatMinutes = static fn (int|float $minutes): string => number_format((float) $minutes, 1).' min';
    @endphp

    <style>
        .timing-report-hero {
            border: 1px solid rgba(var(--admin-primary-color-rgb), 0.12);
            background: linear-gradient(135deg, rgba(var(--admin-primary-color-rgb), 0.1), var(--admin-surface-color) 62%);
        }

        .timing-report-kpi,
        .timing-report-ranking {
            height: 100%;
            border: 1px solid var(--admin-border-color);
            border-radius: 18px;
            background: var(--admin-surface-color);
        }

        .timing-report-kpi .card-body,
        .timing-report-ranking .card-body {
            padding: 1.1rem;
        }

        .timing-report-kpi__label {
            color: var(--admin-muted-text-color);
            font-size: 0.82rem;
            margin-bottom: 0.35rem;
        }

        .timing-report-kpi__value {
            color: var(--admin-text-color);
            font-size: 1.65rem;
            font-weight: 700;
            line-height: 1.15;
        }

        .timing-report-ranking .table {
            min-width: 1180px;
        }

        .timing-report-ranking thead th {
            white-space: nowrap;
            background: var(--admin-background-color, #f7f9fc);
        }

        .timing-report-rank {
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

        .timing-report-score {
            display: inline-flex;
            min-width: 72px;
            justify-content: center;
            padding: 0.3rem 0.65rem;
            border-radius: 999px;
            font-weight: 700;
        }

        .timing-report-score.is-regular {
            color: #146c43;
            background: rgba(25, 135, 84, 0.14);
        }

        .timing-report-score.is-irregular {
            color: #b42318;
            background: rgba(220, 53, 69, 0.12);
        }
    </style>

    <div class="main-content attendance-page">
        <div class="page-breadcrumb d-none d-sm-flex align-items-center mb-3">
            <div class="breadcrumb-title pe-3">Timing Report</div>
            <div class="ps-3">
                <nav aria-label="breadcrumb">
                    <ol class="breadcrumb mb-0 p-0">
                        <li class="breadcrumb-item"><a href="{{ route('admin-dashboard') }}"><i class="bx bx-home-alt"></i></a></li>
                        <li class="breadcrumb-item"><a href="{{ route('admin-attendance-reports') }}">Reports</a></li>
                        <li class="breadcrumb-item active" aria-current="page">Timing Report</li>
                    </ol>
                </nav>
            </div>
        </div>

        <div class="card rounded-4 mb-3 timing-report-hero">
            <div class="card-body">
                <div class="mb-3">
                    <h4 class="mb-1 attendance-title">Employee Timing Report</h4>
                    <p class="mb-0 attendance-muted">
                        Most regular employees are ranked by extra hours worked. Most irregular employees are ranked by scheduled hours not worked.
                    </p>
                </div>

                <form method="get" action="{{ route('admin-attendance-timing-report') }}" class="row g-3 align-items-end">
                    <div class="col-md-2">
                        <label class="form-label">Month</label>
                        <input type="month" name="month" value="{{ $filters['month'] }}" class="form-control">
                    </div>
                    <div class="col-md-2">
                        <label class="form-label">From</label>
                        <input type="date" name="from_date" value="{{ $filters['start_date'] }}" class="form-control">
                    </div>
                    <div class="col-md-2">
                        <label class="form-label">To</label>
                        <input type="date" name="to_date" value="{{ $filters['end_date'] }}" class="form-control">
                    </div>
                    <div class="col-md-2">
                        <label class="form-label">Scope</label>
                        <select name="scope" class="form-select">
                            <option value="all" @selected($filters['scope'] === 'all')>All</option>
                            <option value="ho" @selected($filters['scope'] === 'ho')>HO</option>
                            <option value="branch" @selected($filters['scope'] === 'branch')>Branch</option>
                        </select>
                    </div>
                    <div class="col-md-4">
                        <label class="form-label">State, City or Branch</label>
                        <input type="text" name="location_search" value="{{ $filters['location_search'] }}"
                            class="form-control" list="timingReportLocationOptions"
                            placeholder="Type state, city, branch ID or branch name" autocomplete="off">
                        <datalist id="timingReportLocationOptions">
                            @foreach ($filters['location_options'] as $option)
                                <option value="{{ $option['value'] }}">{{ $option['label'] }}</option>
                            @endforeach
                        </datalist>
                    </div>
                    <div class="col-md-3">
                        <label class="form-label">Employee ID</label>
                        <input type="search" name="emp_id" value="{{ $filters['emp_id'] }}" class="form-control" placeholder="Employee ID">
                    </div>
                    <div class="col-md-4">
                        <label class="form-label">Employee Name</label>
                        <input type="search" name="employee_name" value="{{ $filters['employee_name'] ?? '' }}" class="form-control" placeholder="Employee name">
                    </div>
                    <div class="col-md-3 d-flex gap-2">
                        <button type="submit" class="btn btn-primary w-100">Apply</button>
                        <a href="{{ route('admin-attendance-timing-report') }}" class="btn btn-outline-secondary w-100">Reset</a>
                    </div>
                </form>
            </div>
        </div>

        <div class="row g-3 mb-3">
            <div class="col-12 col-md-6 col-xl">
                <div class="timing-report-kpi"><div class="card-body">
                    <div class="timing-report-kpi__label">Tracked Employees</div>
                    <div class="timing-report-kpi__value">{{ $summary['tracked_employees'] }}</div>
                </div></div>
            </div>
            <div class="col-12 col-md-6 col-xl">
                <div class="timing-report-kpi"><div class="card-body">
                    <div class="timing-report-kpi__label">Employees With Variance</div>
                    <div class="timing-report-kpi__value">{{ $summary['irregular_employees'] }}</div>
                </div></div>
            </div>
            <div class="col-12 col-md-6 col-xl">
                <div class="timing-report-kpi"><div class="card-body">
                    <div class="timing-report-kpi__label">Scheduled Hours</div>
                    <div class="timing-report-kpi__value fs-4">{{ $formatDuration($summary['expected_seconds']) }}</div>
                </div></div>
            </div>
            <div class="col-12 col-md-6 col-xl">
                <div class="timing-report-kpi"><div class="card-body">
                    <div class="timing-report-kpi__label">Worked Hours</div>
                    <div class="timing-report-kpi__value fs-4">{{ $formatDuration($summary['worked_seconds']) }}</div>
                </div></div>
            </div>
            <div class="col-12 col-md-6 col-xl">
                <div class="timing-report-kpi"><div class="card-body">
                    <div class="timing-report-kpi__label">Hours Completion</div>
                    <div class="timing-report-kpi__value">{{ number_format($summary['hours_completion_percent'], 1) }}%</div>
                </div></div>
            </div>
        </div>

        @php
            $rankings = [
                [
                    'title' => 'Top 10 Most Irregular Employees',
                    'rows' => $mostIrregular,
                    'tone' => 'is-irregular',
                    'variance_heading' => 'Hours Short',
                    'variance_key' => 'hours_shortfall_seconds',
                    'empty' => 'No employees with missing scheduled hours were found for this period.',
                ],
                [
                    'title' => 'Top 10 Most Regular Employees',
                    'rows' => $mostRegular,
                    'tone' => 'is-regular',
                    'variance_heading' => 'Extra Hours',
                    'variance_key' => 'extra_hours_seconds',
                    'empty' => 'No employees who met their scheduled hours were found for this period.',
                ],
            ];
        @endphp
        @foreach ($rankings as $ranking)
            <div class="card rounded-4 mb-3 timing-report-ranking">
                <div class="card-body">
                    <div class="d-flex flex-column flex-lg-row justify-content-between gap-2 mb-3">
                        <div>
                            <h5 class="attendance-title mb-1">{{ $ranking['title'] }}</h5>
                            <p class="mb-0 attendance-muted">Scheduled and worked hours include only days with an app or imported HO timing record.</p>
                        </div>
                    </div>
                    <div class="table-responsive">
                        <table class="table table-bordered table-hover align-middle mb-0" data-admin-static-serial="true">
                            <thead>
                                <tr>
                                    <th>Rank</th>
                                    <th>Employee</th>
                                    <th>Location</th>
                                    <th>Shift</th>
                                    <th>Tracked Days</th>
                                    <th>Scheduled</th>
                                    <th>Worked</th>
                                    <th>{{ $ranking['variance_heading'] }}</th>
                                    <th>Completion</th>
                                    <th>Avg Late</th>
                                    <th>Avg Early</th>
                                    <th>Irregular Days</th>
                                </tr>
                            </thead>
                            <tbody>
                                @forelse ($ranking['rows'] as $row)
                                    <tr>
                                        <td><span class="timing-report-rank">{{ $loop->iteration }}</span></td>
                                        <td>
                                            <div class="fw-semibold">{{ $row['employee_name'] }}</div>
                                            <div class="small text-muted">{{ $row['emp_id'] }}{{ $row['designation'] ? ' | '.$row['designation'] : '' }}</div>
                                        </td>
                                        <td>
                                            <div>{{ $row['scope'] }}{{ $row['branch_name'] ? ' | '.$row['branch_name'] : '' }}</div>
                                            <div class="small text-muted">{{ $row['branch_id'] ?: '--' }}</div>
                                        </td>
                                        <td>
                                            @foreach ($row['schedules'] as $schedule)
                                                <div class="{{ $loop->first ? 'fw-semibold' : 'small text-muted' }}">{{ $schedule }}</div>
                                            @endforeach
                                        </td>
                                        <td>{{ $row['tracked_days'] }}</td>
                                        <td>{{ $formatDuration($row['expected_seconds']) }}</td>
                                        <td>{{ $formatDuration($row['worked_seconds']) }}</td>
                                        <td class="fw-semibold">{{ $formatDuration($row[$ranking['variance_key']]) }}</td>
                                        <td><span class="timing-report-score {{ $ranking['tone'] }}">{{ number_format($row['hours_completion_percent'], 1) }}%</span></td>
                                        <td>
                                            <div>{{ $formatMinutes($row['average_late_minutes']) }}</div>
                                            <div class="small text-muted">{{ $row['late_days'] }} late {{ Str::plural('day', $row['late_days']) }}</div>
                                        </td>
                                        <td>
                                            <div>{{ $formatMinutes($row['average_early_logout_minutes']) }}</div>
                                            <div class="small text-muted">{{ $row['early_logout_days'] }} early {{ Str::plural('day', $row['early_logout_days']) }}</div>
                                        </td>
                                        <td>{{ $row['irregular_days'] }}</td>
                                    </tr>
                                @empty
                                    <tr><td colspan="12" class="text-center text-muted py-4">{{ $ranking['empty'] }}</td></tr>
                                @endforelse
                            </tbody>
                        </table>
                    </div>
                </div>
            </div>
        @endforeach
    </div>
@endsection
