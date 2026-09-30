@extends('admin.layout.app')

@section('content')
    <div class="main-content">
        <div class="page-breadcrumb d-none d-sm-flex align-items-center mb-3">
            <div class="breadcrumb-title pe-3">Employee</div>
            <div class="ps-3">
                <ol class="breadcrumb mb-0 p-0">
                    <li class="breadcrumb-item"><a href="{{ route('admin-dashboard') }}"><i class="bx bx-home-alt"></i></a></li>
                    <li class="breadcrumb-item active">Reset Password</li>
                </ol>
            </div>
        </div>

        @if (session('status'))
            <div class="alert alert-success">{{ session('status') }}</div>
        @endif
        @if ($errors->any())
            <div class="alert alert-danger"><ul class="mb-0">@foreach ($errors->all() as $error)<li>{{ $error }}</li>@endforeach</ul></div>
        @endif

        <div class="card rounded-4 mb-4">
            <div class="card-body">
                <h4 class="mb-1">Reset Employee Password</h4>
                <p class="text-muted">Reset an employee's password for every branch login and sign out their active app sessions.</p>
                <form method="get" class="row g-2">
                    <div class="col-md-6"><input type="search" name="search" value="{{ $search }}" class="form-control" placeholder="Search employee ID or name"></div>
                    <div class="col-auto"><button class="btn btn-primary">Search</button></div>
                    <div class="col-auto"><a href="{{ route('admin-employee-reset-password') }}" class="btn btn-outline-secondary">Clear</a></div>
                </form>
            </div>
        </div>

        <div class="card rounded-4">
            <div class="card-body table-responsive">
                <table class="table table-bordered align-middle">
                    <thead><tr><th>Emp ID</th><th>Name</th><th>Login Profiles</th><th style="min-width: 360px">New Password</th></tr></thead>
                    <tbody>
                    @forelse ($employees as $employee)
                        <tr>
                            <td>{{ $employee->empId }}</td><td>{{ $employee->name }}</td>
                            <td>{{ (int) ($credentialCounts[$employee->id] ?? 0) }}</td>
                            <td>
                                <form method="post" action="{{ route('admin-employee-reset-password-update', $employee) }}" class="row g-2">
                                    @csrf
                                    <div class="col"><input type="password" name="password" class="form-control" minlength="6" placeholder="New password" required></div>
                                    <div class="col"><input type="password" name="password_confirmation" class="form-control" minlength="6" placeholder="Confirm password" required></div>
                                    <div class="col-auto"><button class="btn btn-danger" onclick="return confirm('Reset this employee password and sign out active sessions?')">Reset</button></div>
                                </form>
                            </td>
                        </tr>
                    @empty
                        <tr><td colspan="4" class="text-center text-muted">No employees found.</td></tr>
                    @endforelse
                    </tbody>
                </table>
                {{ $employees->links() }}
            </div>
        </div>
    </div>
@endsection
