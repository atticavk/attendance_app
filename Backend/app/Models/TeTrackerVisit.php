<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class TeTrackerVisit extends Model
{
    protected $fillable = [
        'employee_id',
        'emp_id',
        'location_type',
        'branch_id',
        'branch_name',
        'release_place',
        'branch_latitude',
        'branch_longitude',
        'captured_latitude',
        'captured_longitude',
        'distance_from_branch',
        'amount',
        'grams',
        'kms',
        'photo_path',
        'visit_date',
        'visit_time',
    ];

    protected $casts = [
        'branch_latitude' => 'float',
        'branch_longitude' => 'float',
        'captured_latitude' => 'float',
        'captured_longitude' => 'float',
        'distance_from_branch' => 'float',
        'amount' => 'float',
        'grams' => 'float',
        'kms' => 'float',
        'visit_date' => 'date',
    ];

    public function employee(): BelongsTo
    {
        return $this->belongsTo(Employee::class, 'employee_id');
    }
}
