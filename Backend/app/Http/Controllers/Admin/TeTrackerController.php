<?php

namespace App\Http\Controllers\Admin;

use App\Http\Controllers\Controller;
use App\Models\Employee;
use App\Models\TeTrackerVisit;
use Illuminate\Http\Request;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;

class TeTrackerController extends Controller
{
    public function index(Request $request)
    {
        $teEmployees = Employee::query()
            ->whereRaw("UPPER(TRIM(designation)) IN ('TE', 'TRANSACTION EXECUTIVE')")
            ->orderBy('name')
            ->get(['id', 'empId', 'name', 'designation', 'status']);

        $selectedDate = $this->resolveSelectedDate($request->query('date'));
        $selectedEmpId = $this->resolveSelectedEmployeeId($request->query('emp_id'), $teEmployees);
        $selectedEmployee = $teEmployees->first(
            fn (Employee $employee): bool => $this->clean($employee->empId) === $selectedEmpId
        );

        $visits = $selectedEmployee
            ? TeTrackerVisit::query()
                ->where('employee_id', $selectedEmployee->id)
                ->where('visit_date', $selectedDate)
                ->orderBy('visit_time')
                ->orderBy('id')
                ->get()
            : collect();

        $journey = $this->buildJourney($visits);

        return view('admin.attendance.te_tracker', [
            'teEmployees' => $teEmployees,
            'selectedDate' => $selectedDate,
            'selectedDateLabel' => Carbon::parse($selectedDate)->format('d M Y'),
            'selectedEmpId' => $selectedEmpId,
            'selectedEmployee' => $selectedEmployee,
            'visitRows' => $journey['rows'],
            'routePoints' => $journey['routePoints'],
            'summary' => $journey['summary'],
            'maxSelectableDate' => Carbon::now(config('app.timezone', 'Asia/Kolkata'))->toDateString(),
        ]);
    }

    private function buildJourney(Collection $visits): array
    {
        $rows = [];
        $routePoints = [];

        foreach ($visits->values() as $index => $visit) {
            if (! $visit instanceof TeTrackerVisit) {
                continue;
            }

            $branchLatitude = $visit->branch_latitude;
            $branchLongitude = $visit->branch_longitude;
            $point = $branchLatitude !== null && $branchLongitude !== null
                ? [
                    'latitude' => (float) $branchLatitude,
                    'longitude' => (float) $branchLongitude,
                    'branch_id' => $this->clean($visit->branch_id),
                    'branch_name' => $this->clean($visit->branch_name),
                    'visit_time' => $this->formatTime($visit->visit_time),
                    'photo_url' => $this->resolvePhotoUrl('public/'.$visit->photo_path),
                    'is_start' => $index === 0,
                    'sequence' => $index + 1,
                ]
                : null;

            if ($point) {
                $routePoints[] = $point;
            }

            $rows[] = [
                'sequence' => $index + 1,
                'segment_label' => $index === 0 ? '1' : $index.' -> '.($index + 1),
                'visit_time' => $this->formatTime($visit->visit_time),
                'branch_id' => $this->clean($visit->branch_id),
                'branch_name' => $this->clean($visit->branch_name),
                'location_type' => $this->clean($visit->location_type) ?: 'branch',
                'release_place' => $this->clean($visit->release_place),
                'amount' => $visit->amount,
                'grams' => $visit->grams,
                'kms' => $visit->kms,
                'distance_from_branch_label' => $visit->distance_from_branch === null
                    ? '--'
                    : $this->formatDistance((float) $visit->distance_from_branch),
                'distance_from_previous_label' => $index === 0 ? 'Start' : 'Calculating...',
                'cumulative_distance_label' => $index === 0 ? '0 m' : 'Calculating...',
                'captured_location' => $visit->captured_latitude !== null && $visit->captured_longitude !== null
                    ? number_format((float) $visit->captured_latitude, 6).', '.number_format((float) $visit->captured_longitude, 6)
                    : '--',
                'photo_url' => $this->resolvePhotoUrl('public/'.$visit->photo_path),
            ];
        }

        /** @var TeTrackerVisit|null $first */
        $first = $visits->first();
        /** @var TeTrackerVisit|null $last */
        $last = $visits->last();

        return [
            'rows' => $rows,
            'routePoints' => $routePoints,
            'summary' => [
                'total_visits' => count($rows),
                'unique_branches' => $visits
                    ->map(fn (TeTrackerVisit $visit): string => $this->clean($visit->branch_id))
                    ->filter()
                    ->unique()
                    ->count(),
                'total_distance_label' => number_format(
                    (float) $visits->sum(fn (TeTrackerVisit $visit): float => (float) ($visit->kms ?? 0)),
                    2
                ).' km',
                'total_amount_label' => number_format(
                    (float) $visits->sum(fn (TeTrackerVisit $visit): float => (float) ($visit->amount ?? 0)),
                    2
                ),
                'total_grams_label' => number_format(
                    (float) $visits->sum(fn (TeTrackerVisit $visit): float => (float) ($visit->grams ?? 0)),
                    3
                ),
                'start_branch' => $first ? $this->branchLabel($first) : 'No visits',
                'end_branch' => $last ? $this->branchLabel($last) : 'No visits',
            ],
        ];
    }

    private function branchLabel(TeTrackerVisit $visit): string
    {
        if ($this->clean($visit->location_type) === 'release_place') {
            return $this->clean($visit->release_place) ?: 'Release Place';
        }

        $branchId = $this->clean($visit->branch_id);
        $branchName = $this->clean($visit->branch_name);

        return trim($branchId.($branchName !== '' ? ' - '.$branchName : ''));
    }

    private function resolveSelectedEmployeeId(?string $value, Collection $employees): string
    {
        $selected = $this->clean($value);

        if ($selected !== '' && $employees->contains(
            fn (Employee $employee): bool => $this->clean($employee->empId) === $selected
        )) {
            return $selected;
        }

        return $employees
            ->map(fn (Employee $employee): string => $this->clean($employee->empId))
            ->first() ?? '';
    }

    private function resolveSelectedDate(?string $value): string
    {
        $date = $this->clean($value);

        if ($date === '') {
            return Carbon::now(config('app.timezone', 'Asia/Kolkata'))->toDateString();
        }

        try {
            return Carbon::createFromFormat('Y-m-d', $date, config('app.timezone', 'Asia/Kolkata'))->toDateString();
        } catch (\Throwable $exception) {
            return Carbon::now(config('app.timezone', 'Asia/Kolkata'))->toDateString();
        }
    }

    private function resolvePhotoUrl(?string $path): string
    {
        $trimmed = $this->clean($path);

        if ($trimmed === '') {
            return '';
        }

        if (preg_match('/^https?:\/\//i', $trimmed) === 1) {
            return $trimmed;
        }

        $normalizedPath = ltrim($trimmed, '/');


        return asset($normalizedPath);
    }

    private function formatDistance(float $distanceMeters): string
    {
        if ($distanceMeters >= 1000) {
            return number_format($distanceMeters / 1000, 2).' km';
        }

        return round($distanceMeters).' m';
    }

    private function formatTime(?string $value): string
    {
        $trimmed = $this->clean($value);

        if ($trimmed === '') {
            return '--';
        }

        try {
            return Carbon::parse($trimmed)->format('h:i A');
        } catch (\Throwable $exception) {
            return $trimmed;
        }
    }

    private function clean(?string $value): string
    {
        return trim((string) $value);
    }
}
