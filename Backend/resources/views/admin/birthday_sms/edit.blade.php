@extends('admin.layout.app')

@section('content')
<div class="main-content">
    <div class="page-breadcrumb d-none d-sm-flex align-items-center mb-3">
        <div class="breadcrumb-title pe-3">Birthday SMS</div>
    </div>
    @if (session('status')) <div class="alert alert-success">{{ session('status') }}</div> @endif
    @if ($errors->any()) <div class="alert alert-danger"><ul class="mb-0">@foreach ($errors->all() as $error)<li>{{ $error }}</li>@endforeach</ul></div> @endif
    <div class="card border-0 shadow-sm"><div class="card-body p-4">
        <h4 class="mb-1">Birthday SMS automation</h4>
        <p class="text-muted">Send one morning SMS to each active employee whose date of birth is today. Provider credentials are configured only in the server environment.</p>
        <form method="post" action="{{ route('admin-birthday-sms-update') }}" class="row g-3">
            @csrf
            <div class="col-12"><div class="form-check form-switch">
                <input type="hidden" name="enabled" value="0">
                <input class="form-check-input" type="checkbox" name="enabled" value="1" id="birthdaySmsEnabled" @checked(old('enabled', $setting->enabled))>
                <label class="form-check-label fw-semibold" for="birthdaySmsEnabled">Enable birthday SMS</label>
            </div></div>
            <div class="col-md-4"><label class="form-label">Morning send time</label><input class="form-control" type="time" name="send_time" value="{{ old('send_time', substr($setting->send_time, 0, 5)) }}" required></div>
            <div class="col-md-8"><label class="form-label">Service-provider template ID</label><input class="form-control" name="provider_template_id" value="{{ old('provider_template_id', $setting->provider_template_id) }}" placeholder="Enter the approved DLT/provider template ID"></div>
            <div class="col-12"><label class="form-label">Approved SMS template</label><textarea class="form-control" name="message_template" rows="4" maxlength="1000" required>{{ old('message_template', $setting->message_template) }}</textarea><div class="form-text">Required variable: <code>@{{name}}</code>. Submit this exact text to the SMS service provider for approval.</div></div>
            <div class="col-12"><button class="btn btn-primary px-4" type="submit">Save Birthday SMS Settings</button></div>
        </form>
    </div></div>
    <div class="card border-0 shadow-sm mt-4"><div class="card-body p-4"><h5>Recent delivery attempts</h5><div class="table-responsive"><table class="table"><thead><tr><th>Date</th><th>Employee</th><th>Phone</th><th>Status</th><th>Sent</th></tr></thead><tbody>
        @forelse($recentDeliveries as $delivery)<tr><td>{{ optional($delivery->birthday_date)->format('d M Y') }}</td><td>{{ $delivery->employee_id }}</td><td>{{ substr($delivery->phone, 0, 3) }}••••{{ substr($delivery->phone, -2) }}</td><td>{{ ucfirst($delivery->status) }}</td><td>{{ optional($delivery->sent_at)->format('d M Y H:i') ?: '--' }}</td></tr>@empty<tr><td colspan="5" class="text-muted">No birthday SMS attempts yet.</td></tr>@endforelse
    </tbody></table></div></div></div>
</div>
@endsection
