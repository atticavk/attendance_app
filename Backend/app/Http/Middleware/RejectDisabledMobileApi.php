<?php

namespace App\Http\Middleware;

use App\Support\MobileApiState;
use Closure;
use Illuminate\Http\Request;

class RejectDisabledMobileApi
{
    public function __construct(private MobileApiState $state)
    {
    }

    public function handle(Request $request, Closure $next)
    {
        if ($this->state->isDisabled()) {
            return response()->json(['message' => 'Endpoint Error.'], 503);
        }

        return $next($request);
    }
}
