@extends('admin.layout.app')

@section('content')
@php
    $calendarDate = \Illuminate\Support\Carbon::create($year, $month, 1)->startOfDay();
    $daysInMonth = $calendarDate->daysInMonth;
    $leadingDays = $calendarDate->dayOfWeek;
    $trailingDays = (7 - (($leadingDays + $daysInMonth) % 7)) % 7;
    $today = now();
    $previousMonth = $calendarDate->copy()->subMonthNoOverflow();
    $nextMonth = $calendarDate->copy()->addMonthNoOverflow();
    $birthdayCount = $birthdays->flatten(1)->count();
@endphp
<style>
    .birthday-toolbar{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:1rem;margin-bottom:1rem}
    .birthday-month-nav{display:flex;align-items:center;gap:.65rem}
    .birthday-month-nav select{min-width:170px}
    .birthday-calendar{border:1px solid rgba(var(--admin-primary-color-rgb),.14);border-radius:22px;background:var(--admin-surface-color,#fff);box-shadow:0 14px 34px rgba(44,28,80,.08);overflow:hidden}
    .birthday-month-title{padding:1rem 1.25rem;color:#fff;font-size:1.15rem;font-weight:800;background:linear-gradient(135deg,#ffb52e,#ff477e 42%,#7b2cff 78%,#3a56e8)}
    .birthday-week,.birthday-days{display:grid;grid-template-columns:repeat(7,minmax(0,1fr))}
    .birthday-week span{padding:.8rem .25rem;text-align:center;font-size:.8rem;font-weight:800;color:var(--admin-muted-text-color)}
    .birthday-day,.birthday-empty{min-height:108px;padding:.65rem;border-top:1px solid rgba(var(--admin-primary-color-rgb),.09);border-right:1px solid rgba(var(--admin-primary-color-rgb),.09)}
    .birthday-day.is-today{background:linear-gradient(145deg,rgba(255,181,46,.15),rgba(123,44,255,.11))}
    .birthday-date{font-size:.88rem;font-weight:800}
    .birthday-cake{display:flex;align-items:center;justify-content:center;width:48px;height:48px;margin:.35rem auto 0;border:0;border-radius:50%;background:linear-gradient(145deg,#ffb52e,#ff477e 48%,#7b2cff);box-shadow:0 7px 17px rgba(255,71,126,.28);font-size:1.65rem;transition:transform .15s ease,box-shadow .15s ease}
    .birthday-cake .bi{color:#fff;line-height:1}
    .birthday-cake:hover,.birthday-cake:focus{transform:translateY(-2px) scale(1.06);box-shadow:0 10px 22px rgba(123,44,255,.3)}
    .birthday-count{display:block;margin-top:.2rem;text-align:center;font-size:.69rem;font-weight:700;color:var(--admin-muted-text-color)}
    .birthday-employee{padding:.8rem 0;border-bottom:1px solid rgba(var(--admin-primary-color-rgb),.1)}
    .birthday-employee:last-child{border-bottom:0}
    @media(max-width:767px){.birthday-day,.birthday-empty{min-height:76px;padding:.35rem}.birthday-week span{font-size:.68rem}.birthday-cake{width:38px;height:38px;font-size:1.3rem}.birthday-count{display:none}}
</style>

<div class="main-content">
    <div class="birthday-toolbar">
        <div>
            <h3 class="mb-1">Employee Birthday Calendar</h3>
            <div class="text-muted">{{ $birthdayCount }} active employee {{ \Illuminate\Support\Str::plural('birthday', $birthdayCount) }} in {{ $calendarDate->format('F Y') }}</div>
        </div>
        <div class="birthday-month-nav">
            <a class="btn btn-outline-primary" href="{{ route('admin-employee-birthday-calendar', ['month' => $previousMonth->month, 'year' => $previousMonth->year]) }}" aria-label="Previous month">&lsaquo;</a>
            <form method="get">
                <label class="visually-hidden" for="birthdayMonth">Birthday month</label>
                <input type="hidden" name="year" value="{{ $year }}">
                <select class="form-select" id="birthdayMonth" name="month" onchange="this.form.submit()">
                    @for($optionMonth = 1; $optionMonth <= 12; $optionMonth++)
                        <option value="{{ $optionMonth }}" @selected($optionMonth === $month)>{{ \Illuminate\Support\Carbon::create(2000, $optionMonth, 1)->format('F') }}</option>
                    @endfor
                </select>
            </form>
            <a class="btn btn-outline-primary" href="{{ route('admin-employee-birthday-calendar', ['month' => $nextMonth->month, 'year' => $nextMonth->year]) }}" aria-label="Next month">&rsaquo;</a>
        </div>
    </div>

    <section class="birthday-calendar">
        <div class="birthday-month-title">{{ $calendarDate->format('F Y') }}</div>
        <div class="birthday-week">@foreach(['Sun','Mon','Tue','Wed','Thu','Fri','Sat'] as $weekday)<span>{{ $weekday }}</span>@endforeach</div>
        <div class="birthday-days">
            @for($blank = 0; $blank < $leadingDays; $blank++)<div class="birthday-empty" aria-hidden="true"></div>@endfor
            @for($day = 1; $day <= $daysInMonth; $day++)
                @php($employees = $birthdays->get($day, collect()))
                <div class="birthday-day {{ $today->year === $year && $today->month === $month && $today->day === $day ? 'is-today' : '' }}">
                    <div class="birthday-date">{{ $day }}</div>
                    @if($employees->isNotEmpty())
                        <button class="birthday-cake" type="button" data-bs-toggle="modal" data-bs-target="#birthdayList{{ $day }}" aria-label="Show {{ $employees->count() }} birthdays on {{ $calendarDate->format('F') }} {{ $day }}"><i class="bi bi-cake2-fill" aria-hidden="true"></i></button>
                        <span class="birthday-count">{{ $employees->count() }} {{ \Illuminate\Support\Str::plural('birthday', $employees->count()) }}</span>
                    @endif
                </div>
            @endfor
            @for($blank = 0; $blank < $trailingDays; $blank++)<div class="birthday-empty" aria-hidden="true"></div>@endfor
        </div>
    </section>

    @foreach($birthdays as $day => $employees)
        <div class="modal fade" id="birthdayList{{ $day }}" tabindex="-1" aria-labelledby="birthdayListLabel{{ $day }}" aria-hidden="true">
            <div class="modal-dialog modal-dialog-centered">
                <div class="modal-content">
                    <div class="modal-header birthday-month-title">
                        <h5 class="modal-title" id="birthdayListLabel{{ $day }}"><i class="bi bi-cake2-fill me-2" aria-hidden="true"></i>Birthdays on {{ $calendarDate->format('F') }} {{ $day }}</h5>
                        <button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal" aria-label="Close"></button>
                    </div>
                    <div class="modal-body">
                        @foreach($employees as $employee)
                            <div class="birthday-employee">
                                <div class="fw-bold">{{ $employee->name }}</div>
                                <div class="small text-muted">{{ $employee->empId }}{{ $employee->designation ? ' · '.$employee->designation : '' }}</div>
                            </div>
                        @endforeach
                    </div>
                </div>
            </div>
        </div>
    @endforeach
</div>
@endsection
