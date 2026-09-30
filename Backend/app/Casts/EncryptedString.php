<?php

namespace App\Casts;

use Illuminate\Contracts\Database\Eloquent\CastsAttributes;
use Illuminate\Contracts\Encryption\DecryptException;
use Illuminate\Support\Facades\Crypt;

class EncryptedString implements CastsAttributes
{
    public function get($model, string $key, $value, array $attributes): ?string
    {
        if ($value === null || $value === '') {
            return null;
        }

        try {
            return Crypt::decryptString((string) $value);
        } catch (DecryptException) {
            // Support rows that have not yet been converted by the encryption migration.
            return (string) $value;
        }
    }

    public function set($model, string $key, $value, array $attributes): ?string
    {
        $value = trim((string) $value);

        return $value === '' ? null : Crypt::encryptString($value);
    }
}
