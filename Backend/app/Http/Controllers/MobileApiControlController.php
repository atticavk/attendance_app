<?php

namespace App\Http\Controllers;

use App\Support\MobileApiState;
use App\Support\Totp;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\View\View;

class MobileApiControlController extends Controller
{
    public function show(MobileApiState $state): View
    {
        return view('mobile-api-status', ['disabled' => $state->isDisabled()]);
    }

    public function update(Request $request, MobileApiState $state, Totp $totp): RedirectResponse
    {
        if (! $this->hasValidPassword($request)) {
            return back()->withErrors(['password' => 'The password is incorrect.']);
        }

        if (! $totp->verify((string) $request->input('totp_code'), config('mobile_api.totp_secret'))) {
            return back()->withErrors(['totp_code' => 'The Google Authenticator code is invalid or expired.']);
        }

        $action = $request->input('action');

        if ($action === 'deactivate') {
            $state->disable();

            return redirect()->route('mobile-api.status')->with('status', 'Mobile API deactivated.');
        }

        if ($action === 'activate') {
            $state->enable();

            return redirect()->route('mobile-api.status')->with('status', 'Mobile API activated.');
        }

        return back()->withErrors(['action' => 'Invalid action.']);
    }

    private function hasValidPassword(Request $request): bool
    {
        $password = $request->input('password');
        $hash = config('mobile_api.control_password_hash');

        return is_string($password)
            && is_string($hash)
            && $hash !== ''
            && password_verify($password, $hash);
    }
}
