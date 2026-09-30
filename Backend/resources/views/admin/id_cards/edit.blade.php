@extends('admin.layout.app')

@section('content')
<div class="main-content">
    <div class="d-flex align-items-center justify-content-between mb-3">
        <div><h4 class="mb-1">Edit ID Card Submission</h4><p class="text-muted mb-0">Employee ID cannot be changed.</p></div>
        <a href="{{ route('admin-id-cards-index') }}" class="btn btn-outline-secondary">Back</a>
    </div>
    @if($errors->any())<div class="alert alert-danger"><ul class="mb-0">@foreach($errors->all() as $error)<li>{{ $error }}</li>@endforeach</ul></div>@endif
    <div class="card rounded-4"><div class="card-body">
        <form method="post" action="{{ route('admin-id-cards-update', $submission) }}" enctype="multipart/form-data" class="row g-3">
            @csrf @method('PUT')
            <div class="col-md-6"><label class="form-label">Employee ID</label><input class="form-control" value="{{ $submission->emp_id }}" disabled></div>
            <div class="col-md-6"><label class="form-label">Full name</label><input name="full_name" class="form-control" value="{{ old('full_name', $submission->full_name) }}" required></div>
            <div class="col-md-6"><label class="form-label">Designation</label><input name="designation" class="form-control" value="{{ old('designation', $submission->designation) }}" required></div>
            <div class="col-md-3"><label class="form-label">Blood group</label><select name="blood_group" class="form-select" required>@foreach(['A+','A-','B+','B-','AB+','AB-','O+','O-'] as $group)<option value="{{ $group }}" @selected(old('blood_group', $submission->blood_group)===$group)>{{ $group }}</option>@endforeach</select></div>
            <div class="col-md-6"><label class="form-label">Phone</label><input name="phone" class="form-control" pattern="[0-9]{10}" maxlength="10" value="{{ old('phone', $submission->phone) }}" required></div>
            <div class="col-md-6"><label class="form-label">Emergency contact</label><input name="emergency_contact" class="form-control" pattern="[0-9]{10}" maxlength="10" value="{{ old('emergency_contact', $submission->emergency_contact) }}" required></div>
            <div class="col-12"><label class="form-label">Home address</label><textarea name="home_address" class="form-control" rows="3" required>{{ old('home_address', $submission->home_address) }}</textarea></div>
            <div class="col-md-6"><label class="form-label">Status</label><select name="status" class="form-select" required>@foreach(['pending','approved'] as $status)<option value="{{ $status }}" @selected(old('status', $submission->status)===$status)>{{ ucfirst($status) }}</option>@endforeach</select></div>
            <div class="col-md-6"><label class="form-label">Replace photo <small class="text-muted">(optional)</small></label><input type="file" name="photo" class="form-control" accept="image/jpeg,image/png,image/webp"></div>
            <div class="col-12"><label class="form-label">Admin notes</label><textarea name="admin_notes" class="form-control" rows="3">{{ old('admin_notes', $submission->admin_notes) }}</textarea></div>
            <div class="col-12 d-flex gap-2"><button class="btn btn-primary">Save Changes</button><a class="btn btn-outline-primary" href="{{ route('admin-id-cards-card', $submission) }}">Preview ID Card</a></div>
        </form>
    </div></div>
</div>
@endsection
