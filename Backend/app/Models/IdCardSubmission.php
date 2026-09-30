<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\SoftDeletes;

class IdCardSubmission extends Model
{
    use HasFactory, SoftDeletes;

    protected $fillable = [
        'employee_id', 'emp_id', 'full_name', 'designation', 'date_of_birth',
        'blood_group', 'phone', 'emergency_contact', 'home_address',
        'photo_path', 'status', 'admin_notes',
    ];

    protected $casts = [
        'date_of_birth' => 'date',
    ];

    public function employee(): BelongsTo
    {
        return $this->belongsTo(Employee::class);
    }
}
