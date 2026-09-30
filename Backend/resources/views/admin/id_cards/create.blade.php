@extends('admin.layout.app')

@section('content')
<div class="main-content">
    <div class="d-flex align-items-center justify-content-between mb-3"><div><h4 class="mb-1">Add ID Card</h4><p class="text-muted mb-0">Create a submission for an employee.</p></div><a href="{{ route('admin-id-cards-index') }}" class="btn btn-outline-secondary">Back</a></div>
    @if($errors->any())<div class="alert alert-danger"><ul class="mb-0">@foreach($errors->all() as $error)<li>{{ $error }}</li>@endforeach</ul></div>@endif
    <div class="card rounded-4"><div class="card-body">
        <form method="post" action="{{ route('admin-id-cards-store') }}" enctype="multipart/form-data" class="row g-3" id="id-card-form">@csrf
            <div class="col-md-6"><label class="form-label">Employee</label><select name="employee_id" id="employee_id" class="form-select" required><option value="">Select employee</option>@foreach($employees as $employee)<option value="{{ $employee->id }}" data-name="{{ $employee->name }}" data-designation="{{ $employee->designation }}" data-phone="{{ $employee->contact }}" data-address="{{ $employee->address }}">{{ $employee->empId }} — {{ $employee->name }}</option>@endforeach</select></div>
            <div class="col-md-6"><label class="form-label">Full name</label><input name="full_name" id="full_name" class="form-control" value="{{ old('full_name') }}" required></div>
            <div class="col-md-6"><label class="form-label">Designation</label><input name="designation" id="designation" class="form-control" value="{{ old('designation') }}" required></div>
            <div class="col-md-3"><label class="form-label">Blood group</label><select name="blood_group" class="form-select" required><option value="">Select</option>@foreach(['A+','A-','B+','B-','AB+','AB-','O+','O-'] as $group)<option @selected(old('blood_group')===$group)>{{ $group }}</option>@endforeach</select></div>
            <div class="col-md-6"><label class="form-label">Phone</label><input name="phone" id="phone" class="form-control" pattern="[0-9]{10}" maxlength="10" value="{{ old('phone') }}" required></div>
            <div class="col-md-6"><label class="form-label">Emergency contact</label><input name="emergency_contact" class="form-control" pattern="[0-9]{10}" maxlength="10" value="{{ old('emergency_contact') }}" required></div>
            <div class="col-12"><label class="form-label">Home address</label><textarea name="home_address" id="home_address" class="form-control" rows="3" required>{{ old('home_address') }}</textarea></div>
            <div class="col-md-6"><label class="form-label">Passport-style photo</label><input type="file" name="photo" class="form-control" accept="image/jpeg,image/png,image/webp" required></div>
            <div class="col-12"><button class="btn btn-primary">Submit ID Card</button></div>
        </form>
    </div></div>
</div>
<script>
document.getElementById('employee_id').addEventListener('change', function () {
    const o=this.options[this.selectedIndex]; if(!o.value)return;
    for (const [id,key] of [['full_name','name'],['designation','designation'],['phone','phone'],['home_address','address']]) document.getElementById(id).value=o.dataset[key]||'';
});
</script>
@endsection
