<?php

namespace App\Support;

use Illuminate\Support\Facades\Cache;

class MobileApiState
{
    private const CACHE_KEY = 'mobile_api:disabled';

    public function isDisabled(): bool
    {
        return (bool) Cache::get(self::CACHE_KEY, false);
    }

    public function disable(): void
    {
        Cache::forever(self::CACHE_KEY, true);
    }

    public function enable(): void
    {
        Cache::forget(self::CACHE_KEY);
    }
}
