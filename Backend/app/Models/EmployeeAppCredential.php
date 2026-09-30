<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class EmployeeAppCredential extends Model
{
    protected $fillable = [
        'employee_id',
        'emp_id',
        'branch_id',
        'password_hash',
        'password_set_at',
        'last_login_at',
    ];

    protected $casts = [
        'password_set_at' => 'datetime',
        'last_login_at' => 'datetime',
    ];

    protected $hidden = [
        'password_hash',
    ];

    public function employee(): BelongsTo
    {
        return $this->belongsTo(Employee::class, 'employee_id');
    }
}
