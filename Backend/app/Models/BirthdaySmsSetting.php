<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class BirthdaySmsSetting extends Model
{
    public const DEFAULT_TEMPLATE = 'Dear {{name}}, Attica Gold wishes you a very Happy Birthday! May your year be filled with joy, good health and success. - Attica Gold';

    protected $fillable = ['enabled', 'send_time', 'provider_template_id', 'message_template', 'updated_by'];

    protected $casts = ['enabled' => 'boolean'];

    public static function current(): self
    {
        return self::query()->firstOrCreate([], [
            'enabled' => false,
            'send_time' => '09:00:00',
            'message_template' => self::DEFAULT_TEMPLATE,
        ]);
    }
}
