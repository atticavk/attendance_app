<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class BranchOpeningNotificationLog extends Model
{
    protected $fillable = [
        'branch_id',
        'employee_id',
        'notification_type',
        'notification_key',
        'title',
        'body',
        'sent_at',
    ];

    protected $casts = [
        'sent_at' => 'datetime',
    ];
}
