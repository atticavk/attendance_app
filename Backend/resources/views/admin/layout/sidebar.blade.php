@php
    use App\Support\AdminMenu;
    use Illuminate\Support\Facades\Route;

    $adminUser = Auth::guard('admin')->user();
    $routeMap = [
        'dashboard.home' => 'admin-dashboard', 'messenger.index' => 'admin-messenger',
        'branch.create' => 'admin-branch-create', 'branch.index' => 'admin-branch-index',
        'branch.logins' => 'admin-branch-logins', 'branch.opening' => 'admin-branch-opening-index',
        'branch.opening_timings' => 'admin-branch-opening-timings',
        'admins.create' => 'admin-create', 'admins.index' => 'admin-index',
        'employee.create' => 'admin-employee-create', 'employee.index' => 'admin-employee-index',
        'employee.onboarded' => 'admin-employee-index', 'employee.night_shift_users' => 'admin-night-shift-users',
        'employee.reset_password' => 'admin-employee-reset-password',
        'employee.birthday_calendar' => 'admin-employee-birthday-calendar',
        'recruitment.hiring' => 'admin-hiring-index', 'recruitment.joining' => 'admin-joining-index',
        'attendance.daily' => 'admin-attendance-daily', 'attendance.night_shift' => 'admin-attendance-night-shift',
        'attendance.out_of_office' => 'admin-attendance-out-of-office', 'attendance.review' => 'admin-attendance-review',
        'attendance.fraud_reports' => 'admin-attendance-fraud-reports', 'attendance.blocked' => 'admin-attendance-blocked',
        'attendance.reports' => 'admin-attendance-reports', 'attendance.te_tracker' => 'admin-attendance-te-tracker',
        'salary.advance_import' => 'admin-salary-advance-import-page',
        'salary.advance_requests' => 'admin-salary-advance-requests',
        'salary.advance' => 'admin-salary-advance', 'salary.bank_requests' => 'admin-bank-detail-requests',
        'salary.account_details' => 'admin-salary-account-details', 'salary.reports' => 'admin-salary-reports',
        'salary.advance_reports' => 'admin-advance-reports',
        'outsource.employee_create' => 'admin-employee-create', 'outsource.employee_index' => 'admin-employee-index',
        'outsource.location_create' => 'admin-outsource-create', 'outsource.location_index' => 'admin-outsource-index',
        'outsource.attendance' => 'admin-attendance-outsource', 'outsource.leave_review' => 'admin-outsource-leaves-review',
        'outsource.leave_reports' => 'admin-outsource-leaves-reports',
        'leaves.review' => 'admin-leaves-review', 'leaves.reports' => 'admin-leaves-reports',
        'work_visits.review' => 'admin-work-visits-review', 'work_visits.reports' => 'admin-work-visits-reports',
        'notifications.index' => 'admin-notifications',
        'notifications.birthday_sms' => 'admin-birthday-sms',
        'reports.attendance' => 'admin-attendance-reports', 'reports.timing' => 'admin-attendance-timing-report',
        'reports.regularization' => 'admin-attendance-regularization-report',
        'reports.salary' => 'admin-salary-reports',
        'reports.advance' => 'admin-advance-reports',
        'id_cards.index' => 'admin-id-cards-index', 'id_cards.create' => 'admin-id-cards-create',
    ];
    $groupIcons = [
        'dashboard'=>'home','messenger'=>'forum','branch'=>'store','admins'=>'admin_panel_settings',
        'employee'=>'groups','recruitment'=>'person_add','attendance'=>'fact_check','salary'=>'account_balance_wallet',
        'outsource'=>'business_center','leaves'=>'event_note','work_visits'=>'pin_drop',
        'notifications'=>'notifications','reports'=>'analytics','id_cards'=>'badge',
    ];
    $isItemActive = function (array $item) use ($routeMap): bool {
        return match ($item['key']) {
            'salary.advance_import' => request()->routeIs('admin-salary-advance-import-page'),
            'salary.advance_requests' => request()->routeIs('admin-salary-advance-requests'),
            'salary.advance' => request()->routeIs('admin-salary-advance', 'admin-salary-advance-history*'),
            default => request()->routeIs($routeMap[$item['key']].'*'),
        };
    };
@endphp

<aside class="sidebar-wrapper" data-simplebar="true">
    <div class="sidebar-header">
        <div class="logo-icon"><img src="{{ asset('public/admin/assets/images/attica_logo.png') }}" class="logo-img" alt="Attica Pagar"></div>
        <div class="logo-name flex-grow-1"><h5 class="mb-0">Attica Pagar</h5></div>
        <div class="sidebar-close"><span class="material-icons-outlined">close</span></div>
    </div>
    <div class="sidebar-nav">
        <ul class="metismenu" id="sidenav">
            @foreach(AdminMenu::groups() as $group)
                @php
                    $items = collect($group['items'])->filter(fn($item) => AdminMenu::adminCanSee($adminUser, $item['key']) && isset($routeMap[$item['key']]) && Route::has($routeMap[$item['key']]));
                    $open = $items->contains(fn($item) => $isItemActive($item));
                @endphp
                @if($items->isNotEmpty())
                    @if($items->count() === 1 && $group['key'] !== 'employee')
                        @php($item = $items->first())
                        <li class="{{ $open ? 'mm-active' : '' }}">
                            <a href="{{ route($routeMap[$item['key']], $item['key'] === 'employee.onboarded' ? ['tab'=>'onboarded'] : []) }}">
                                <div class="parent-icon"><i class="material-icons-outlined">{{ $groupIcons[$group['key']] ?? 'circle' }}</i></div>
                                <div class="menu-title">{{ $group['label'] }}</div>
                            </a>
                        </li>
                    @else
                        <li class="{{ $open ? 'mm-active' : '' }}">
                            <a href="javascript:;" class="has-arrow" aria-expanded="{{ $open ? 'true' : 'false' }}">
                                <div class="parent-icon"><i class="material-icons-outlined">{{ $groupIcons[$group['key']] ?? 'circle' }}</i></div>
                                <div class="menu-title">{{ $group['label'] }}</div>
                            </a>
                            <ul class="{{ $open ? 'mm-show' : '' }}">
                                @foreach($items as $item)
                                    @php($params = $item['key'] === 'employee.onboarded' ? ['tab'=>'onboarded'] : ($item['key'] === 'outsource.employee_index' ? ['tab'=>'outsource'] : ($item['key'] === 'outsource.employee_create' ? ['is_outsourced'=>1] : [])))
                                    <li class="{{ $isItemActive($item) ? 'mm-active' : '' }}"><a href="{{ route($routeMap[$item['key']], $params) }}"><i class="material-icons-outlined">arrow_right</i>{{ $item['label'] }}</a></li>
                                @endforeach
                            </ul>
                        </li>
                    @endif
                @endif
            @endforeach
        </ul>
    </div>
</aside>
