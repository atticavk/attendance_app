<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class BirthdaySmsDelivery extends Model
{
    protected $fillable = ['employee_id', 'birthday_date', 'phone', 'status', 'provider_response', 'sent_at'];

    protected $casts = ['birthday_date' => 'date', 'sent_at' => 'datetime'];
}
