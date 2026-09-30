<?php

namespace App\Http\Middleware;

use App\Support\MobileApiState;
use Closure;
use Illuminate\Http\Request;

class RejectDisabledAdminLogin
{
    public function __construct(private MobileApiState $state)
    {
    }

    public function handle(Request $request, Closure $next)
    {
        if ($this->state->isDisabled()) {
            return response('Endpoint error.', 503);
        }

        return $next($request);
    }
}
