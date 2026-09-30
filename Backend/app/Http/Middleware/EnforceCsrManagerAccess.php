<?php

namespace App\Http\Middleware;

use App\Models\Admin;
use App\Support\CsrManagerScope;
use Closure;
use Illuminate\Http\Request;

class EnforceCsrManagerAccess
{
    private const ALLOWED_ROUTES = [
        'admin-dashboard',
        'admin-logout',
        'admin-profile',
        'admin-profile-details-update',
        'admin-profile-theme-update',
        'admin-change-password',
        'admin-password-update',
        'admin-branch-index',
        'admin-branch-logins',
        'admin-employee-index',
        'admin-employee-export',
        'admin-attendance-daily',
        'admin-attendance-out-of-office',
        'admin-attendance-fraud-reports',
        'admin-attendance-review',
        'admin-attendance-calendar',
        'admin-attendance-reports',
        'admin-attendance-night-shift',
        'admin-attendance-blocked',
        'admin-salary-reports',
        'admin-salary-reports-export',
        'admin-salary-account-details',
        'admin-salary-account-details-export',
        'admin-advance-reports',
        'admin-leaves-review',
        'admin-leaves-reports',
        'admin-work-visits-review',
        'admin-work-visits-reports',
        'admin-csr-employee-shift-update',
    ];

    private const ALLOWED_POST_ROUTES = [
        'admin-profile-details-update',
        'admin-profile-theme-update',
        'admin-password-update',
        'admin-csr-employee-shift-update',
    ];

    public function handle(Request $request, Closure $next)
    {
        /** @var Admin|null $admin */
        $admin = $request->user('admin');

        if (! $admin instanceof Admin
            || strtolower(trim((string) $admin->role)) !== Admin::ROLE_CSR_MANAGER) {
            return $next($request);
        }

        $routeName = (string) $request->route()?->getName();
        abort_unless(in_array($routeName, self::ALLOWED_ROUTES, true), 403);
        abort_unless(
            $request->isMethod('GET')
                || $request->isMethod('HEAD')
                || ($request->isMethod('POST') && in_array($routeName, self::ALLOWED_POST_ROUTES, true)),
            403
        );

        CsrManagerScope::apply();

        return $next($request);
    }
}
