<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Facades\Schema;

class SalaryCalculationSetting extends Model
{
    protected $fillable = ['fixed_30_days', 'pf_enabled', 'updated_by'];

    protected $casts = [
        'fixed_30_days' => 'boolean',
        'pf_enabled' => 'boolean',
    ];

    public static function configuration(): array
    {
        if (! Schema::hasTable('salary_calculation_settings')) {
            return ['fixed_30_days' => false, 'pf_enabled' => true];
        }

        $setting = self::query()->firstOrCreate([], [
            'fixed_30_days' => false,
            'pf_enabled' => true,
        ]);

        return [
            'fixed_30_days' => (bool) $setting->fixed_30_days,
            'pf_enabled' => (bool) $setting->pf_enabled,
        ];
    }
}
