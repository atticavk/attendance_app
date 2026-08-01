# Attica Attendance — User Guide

Last reviewed: 2026-08-01  
Documented version: 5.0.22 (build 5023)

## Purpose and requirements

Attica Attendance is the employee portal for attendance, work-location reporting, company notifications, requests, salary information, ID-card details, and profile maintenance. Options depend on the permissions returned for the employee account.

You need an active employee account, internet access, and a supported device. Camera access is required for attendance and profile/ID-card photographs. Precise location is required for attendance and supported field workflows. Notification permission and exact alarms support reminders. Keep automatic date, time, and time zone enabled. Mock-location tools are not permitted and may cause attendance rejection.

## Install and update

1. Install only from an organization-approved store, portal, or release link.
2. Open **Attica Attendance** and grant permissions needed for your work.
3. If a required-update screen appears, select **Update now**. An obsolete version may be blocked by the service.

Do not install APKs from unknown senders or weaken device security to install the app. Normal updates preserve the session and preferences.

## Sign in

1. Connect to the internet and open the app.
2. Enter the employee username/identifier and password supplied by Attica.
3. Enable **Remember credentials** only on a private, secured device.
4. Select **Login**.
5. If prompted, set and confirm a new password.

Always sign out before returning or sharing a device. The app may return to login automatically when a server session expires.

## Dashboard

The dashboard can provide:

- My Attendance and attendance history/reports
- Branch opening/closing
- Notifications
- Salary
- Leave and advance requests
- Site visit requests and TE Tracker
- ID Card
- Profile, bank details, UAN details, and password changes

Pull to refresh or use the displayed refresh control when information is outdated.

## Check in

1. Open **My Attendance**.
2. Allow precise location and camera access.
3. Wait for the app to resolve the current location and branch.
4. Select check in and capture a clear front-camera photograph. Use good light and keep the whole face visible.
5. Review the details and submit.
6. Wait for the success confirmation, then refresh and confirm the recorded status.

## Check out

1. Open **My Attendance** and let the latest record load.
2. Select check out.
3. Review and confirm any early-checkout warning.
4. Complete location/photo capture when requested and submit.
5. Wait for confirmation and verify the updated status.

The server is the source of truth. A photograph or loading indicator alone does not mean attendance was recorded. Do not submit repeatedly while a request is processing.

While attendance is active, the app may send location updates required by company policy. Attendance may be rejected if location is disabled, permission is insufficient, the device is outside an allowed area, or mock-location behavior is detected. Follow the in-app settings action, correct the issue, return, and retry.

## Branch opening and closing

Authorized employees can open **Branch opening**, verify the branch and current state, then mark it opened or closed. Wait for server confirmation. Reminders may be scheduled from the assigned branch opening time.

## Notifications and reminders

The app receives administrative push messages and schedules local attendance/branch reminders. Open **Notifications** to review messages and mark them read.

If notifications are missing, enable the app's notification channels, permit exact alarms when requested, remove restrictive battery/background settings, verify automatic date/time, and open the signed-in app to refresh device registration. Signing out removes the device token where possible and clears reminder state.

## Employee services

- **Leave:** review prior requests, create a request, complete dates/details, submit, and revisit the page for status.
- **Advance:** review prior requests, enter required amount/details, and submit. Submission is not approval.
- **Site visits:** complete the visit/location fields returned by the service and submit.
- **TE Tracker:** authorized users select a branch, check in for a visit, and review visit history. Location may be required.
- **Salary and Reports:** select an available period to view server-provided summaries and attendance history.
- **ID Card:** view eligibility/status and submit required information or images.
- **Profile:** review supported personal information, update a photograph or fields, change password, and submit enabled bank/UAN changes. Some updates require administrative approval.

## Salary administration

Authorized HR/accounts administrators now use three separate entries under **Salary**:

- **Import Advance:** upload CSV/XLS/XLSX advance files, review skipped rows, and confirm or cancel conflicts with manual entries.
- **Advance Requests:** filter requests from the employee app, download the request spreadsheet, select multiple requests for approval/rejection, or review and act on one request with an optional note.
- **Add Advance Details:** review employee advance totals and manually add a dated advance entry. Use **View Details** to inspect an employee's ledger.

The pages are separate so opening or submitting one workflow does not wait for the other two data sets to load. After an action, the administrator remains on the relevant page. The sidebar highlights only the advance page currently open; employee advance history remains associated with **Add Advance Details**.

On **Salary > Account Details**, use **Employee Status** to show all employees, only active employees, or only inactive employees. The selected status combines with branch, state, and employee-name filters and is also applied to **Download Excel**.

## Sign out

Open the profile/account menu, select **Logout**, and confirm. Sign out on shared devices.

## Troubleshooting

### Cannot connect or sign in

- Test internet access, confirm credentials without extra spaces, and correct device date/time.
- Retry after a short interval if the service is unavailable.
- Contact support for an inactive/locked account or password reset.

### Camera does not open

- Enable camera under Android **Settings > Apps > Attica Attendance > Permissions**.
- Close other apps using the camera, then restart the app or device.

### Location is unavailable or rejected

- Enable device location and precise-location permission.
- Disable mock-location apps and developer location overrides.
- Move to an open area for a better GPS fix and confirm internet access.
- Follow the app link to location, wireless, or developer settings.

### Attendance looks wrong

- Refresh **My Attendance** and avoid duplicate submission.
- Record the employee ID, date/time, version/build, and exact message, then contact support.

### Safe support information

Share the app version/build, device model, Android version, employee ID, date/time, and exact error. Never send a password, session token, signing file, or full bank credentials.

## Privacy and security

The app processes identity, attendance, location, photographs, notification device identifiers, employment information, and request data needed for its functions. Use it only for authorized work. Protect the device with a screen lock, keep Android updated, avoid rooted/shared devices when possible, and report a lost device promptly.

## Documentation change log

- 2026-08-01 — Version 5.0.22+5023 — Documented exact advance sidebar highlighting and the Account Details active/inactive employee filter.
- 2026-08-01 — Version 5.0.22+5023 — Documented the three separate Salary advance administration pages and their faster independent loading.
- 2026-08-01 — Version 5.0.22+5023 — Created the end-to-end user guide.
