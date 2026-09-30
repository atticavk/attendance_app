# Attica Attendance - User Guide

Last reviewed: 2026-10-01
Documented version: 5.0.36 (build 5037)

## Purpose and requirements

Attica Attendance is the employee portal for attendance, work-location reporting, company notifications, requests, salary information, ID-card details, and profile maintenance. Options depend on the permissions returned for the employee account.

You need an active employee account, internet access, and a supported device. Camera access is required for attendance and profile/ID-card photographs. Precise location is required for attendance and supported field workflows. Notification permission and exact alarms support reminders. Keep automatic date, time, and time zone enabled. Mock-location tools are not permitted and may cause attendance rejection.

## Install and update

For a new local installation from the complete repository, follow the root [README](../../README.md). Local setup creates a fictional administrator, branch and employee and prints unique login passwords once. Use the employee branch/employee identifiers and generated password in the app; use the generated admin credentials at `/admin/login`. Real staff, past attendance, photos and payroll records require a separate authorized restoration of the existing business database and files.

Local demo attendance still requires camera/location permission and a branch location matching the test device. An administrator can edit the demo branch coordinates. Firebase push, SMS, external employee sync and authenticated map tiles require service configuration; those services are not activated by the clean local setup. Production app builds must point to the organization's server. Reset a previously saved server address if a test installation still connects to an old environment.

Administrators creating another administrator account select its Admin Type and menu permissions, then receive a generated initial password displayed once; share it privately with the intended recipient. VM password login is available only when the server administrator configures it. Private payroll allowlists and salary overrides must be restored before relying on payroll totals in a recovered production installation.

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

If a check-in is submitted again for the same employee and check-in date, the server keeps one attendance entry and updates that entry with the latest submitted check-in details instead of creating a duplicate row.

While attendance is active, the app may send location updates required by company policy. Attendance may be rejected if location is disabled, permission is insufficient, the device is outside an allowed area, or mock-location behavior is detected. Follow the in-app settings action, correct the issue, return, and retry.

### Attendance blocking for new joiners

Recently joined employees are not automatically attendance-blocked during the first seven calendar days beginning with their Date of Joining. For example, an employee joining on 1 September is protected from 1â€“7 September. Absence counting for the three-consecutive-working-day blocking rule begins on 8 September; absences during the seven-day onboarding period do not carry into that count. A valid Date of Joining must be saved on the employee record for this protection to apply.

## Branch map

The admin Branch Map can be zoomed in for branch detail, but the map is locked from zooming farther out than the India-region overview.

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

In Attendance Reports, the current date remains pending until the day is completed. If there is no check-in yet, the table shows **Login Pending** and the day is not counted as absent. After check-in, the row shows **Logout Pending** until check-out is recorded. The **Single Punches** card shows finalized historical single-punch days for the selected month, so today's active **Logout Pending** row is not counted as a finalized single punch until the day is no longer active.
- **ID Card:** view eligibility/status and submit required information or images.
- **Profile:** review supported personal information, update a photograph or fields, change password, and submit enabled bank/UAN changes. Some updates require administrative approval.

On **My Profile**, the signed-in employee's Aadhaar number, PAN number, bank account number, IFSC code, and UAN number are shown as readable text when those details are available. These values remain encrypted in backend database storage; only the authenticated employee profile response converts them to readable values for display. Protect screenshots and do not expose this page on shared or unattended devices.

The **Employment** section shows **Shift Timings** for your assigned shift. Date of birth remains in the personal profile section and is no longer repeated under Employment.

## Salary administration

Authorized HR/accounts administrators now use three separate entries under **Salary**:

- **Import Advance:** upload CSV/XLS/XLSX advance files, review skipped rows, and confirm or cancel conflicts with manual entries.
- **Advance Requests:** filter requests from the employee app, download the request spreadsheet, select multiple requests for approval/rejection, or review and act on one request with an optional note.
- **Add Advance Details:** review employee advance totals and manually add a dated advance entry. Use **View Details** to inspect an employee's ledger.

The pages are separate so opening or submitting one workflow does not wait for the other two data sets to load. After an action, the administrator remains on the relevant page. The sidebar highlights only the advance page currently open; employee advance history remains associated with **Add Advance Details**.

On **Salary > Account Details**, use **Employee Status** to show all employees, only active employees, or only inactive employees. The selected status combines with branch, state, and employee-name filters and is also applied to **Download Excel**.

## Employee directory administration

On **All Employees**, select the Active, Inactive, or Outsource tab and apply any search, status, state, city, or branch filters needed. The **Status** filter offers Active, Blocked, and Inactive options and combines with the selected tab. Select the **ID**, **Designation**, **Shift Timing**, or **Last Login Branch** table heading to sort by that column; select it again to reverse the order. The selected filters and header sort also apply to **Download Excel**, which downloads all matching employees for that tab rather than only the visible page. Newly Onboarded candidates are not included in this employee export.

The **Last Login Branch** also uses the employee's latest attendance check-in or check-out when the saved login branch is unavailable. Branch IDs with extra spaces or different letter casing are matched automatically. If the branch is no longer present in the branch master, its recorded branch ID is shown so the column does not appear blank.

Shift timings are shown in the consistent 12-hour format `HH:MM AM - HH:MM PM`; for example, `9:30 AM - 6 PM` appears as `09:30 AM - 06:00 PM`. A blank or invalid timing uses the default `09:30 AM - 07:00 PM`. New employee entries, imports, and recruitment joins save timings in this standard format.

## Recruitment administration

The protected MD account can view the complete candidate lists under **Recruitment > Hiring** and **Recruitment > Joining**. Its profile position does not limit candidate visibility. HR Admin and Sub HR accounts also retain complete recruitment visibility.

Dedicated **Hiring** and **Joining** operator accounts remain limited to candidates matching the position assigned on their admin profile. If one of those operator accounts has no expected records, verify that its assigned position matches the candidate's **Position Applied For** value.

In **Recruitment > Joining**, the Joining user can enter or revise the candidate's Fixed Salary only before an Employee ID is assigned and before the candidate is marked on duty. After either event, that value is shown as read-only on the Joining form and in the Mark Onboarded popup. Administrators change an employee's salary from **All Employees > Edit** after the employee record exists.

## Timing report administration

Only an administrator whose role is **MD** can see and open **Reports > Timing Report**. Select a month or a date range within that month, then optionally filter by scope, location, employee ID, or employee name. Other admin roles cannot see the menu item or open the report URL.

The page displays the top 10 most irregular and top 10 most regular employees. **Most Regular** includes employees who met or exceeded scheduled hours and ranks the largest extra time (`worked âˆ’ scheduled`) first. **Most Irregular** includes employees below scheduled hours and ranks the largest shortage (`scheduled âˆ’ worked`) first. Irregular days and average late/early minutes resolve ties. Scheduled and worked hours cover only dates that contain an app-attendance or imported HO timing record; they are not a count of every calendar workday in the selected period.

The shift shown and scheduled hours are resolved separately for each attendance date from the employee's effective-dated shift history. The normal 10-minute attendance grace period applies before late-coming or early-leaving minutes are counted. If both imported HO and app attendance exist for the same date, imported HO timing is used for this report.

## Regularization report administration

Only an administrator whose role is **MD** can see or open **Reports > Regularization Report**. Choose a month and a locationâ€”**All Locations**, **Head Office**, or an individual stateâ€”then select **Apply**. Employees are ordered from the most regularized attendance days to the fewest for that selection. State selections cover branch records in that state and exclude Head Office.

Each employee/date is counted once, even when more than one attendance source contains an override. The **Regularized By** column shows each responsible administrator and their count. Select **View entries** to see the attendance date, final status, administrator, and source for every counted day. For older direct attendance overrides created before actor tracking, the report uses the matching employee regularization notification to recover the administrator when possible. Entries without a trustworthy historical match display **Not recorded (legacy)**; they are never attributed to a guessed user. Detail tables do not add an extra serial-number column because ranking applies only to the main employee table.

An entry with **Full Day Remote** status comes from an approved Work Visit. Its source displays **Work Visit**, and **Regularized By** displays the Work Visit request's **Reviewed By** value.

## CSR TL access

CSR TL accounts see employees whose designation contains **CSR** and employees designated **Telecaller**. This applies across the CSR TL employee and related scoped views. The shift-timing editor also accepts both groups.

CSR Manager / TL users can open the account menu in the top-right corner and select **Profile**. The profile page allows them to update their own name, email, phone, position, address, and photo, as well as theme, colors, card shape, table density, and the default sidebar state. **Change Password** in the same account menu remains available for updating their own password. These self-service settings do not grant permission to edit operational records.

## Add the admin portal to the home screen

Open the admin portal in Chrome, open the Chrome menu, and select **Add to Home screen** or **Install app**. The saved shortcut uses the white Attica Tracker logo on an Attica-red background and opens the admin dashboard; signed-out users are redirected to login normally.

If an older shortcut shows the previous or generic icon, remove that shortcut, close and reopen Chrome, revisit the admin portal, and add it again. Chrome and Android can retain the icon selected when a shortcut was first created.

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

## Employee inactive audit

When an administrator marks an employee inactive, the system automatically records the signed-in operator alongside the reason and last working date. The recorded identity is retained on reactivation and replaced by the operator of the next inactive action. Older inactive records have no recorded operator.

## Documentation change log

- 2026-10-01 - Documented the complete frontend/backend repository, local fictional demo accounts, generated administrator passwords, optional services, branch-location setup and private production restore requirements.

- 2026-09-22 - Clarified Attendance Reports current-day pending states and single-punch totals: no check-in shows Login Pending, active check-in shows Logout Pending, and finalized historical single punches remain visible.

- 2026-09-22 - Prepared Android version 5.0.36 (build 5037) with the Attendance Reports pending-state and Single Punches fixes.

- 2026-09-17 - Documented automatic operator attribution when marking employees inactive.

- 2026-09-16 â€” Made Last Login Branch fall back to the latest check-in/check-out branch, including normalized legacy branch IDs, with the recorded branch ID shown when branch master details are unavailable.

- 2026-09-16 â€” Added All Employees sorting by employee ID, branch, designation, and shift timing; standardized shift timing display and default values.

- 2026-09-16 â€” Added an Active, Blocked, and Inactive status filter to All Employees and its Excel download.

- 2026-09-16 â€” Moved All Employees sorting to clickable column headings with ascending/descending order retained in Excel downloads.

- 2026-09-16 â€” Added All Employees Excel downloads that respect the selected employee tab and directory filters.

- 2026-09-11 - The admin branch map uses the CARTO Voyager basemap with an API key. If tiles display "API KEY REQUIRED", ask the administrator to configure the CARTO key and refresh the page. Branch markers and filters work as before.

- 2026-09-05 â€” Prepared Android version 5.0.35 (build 5036) with Shift Timings under My Profile > Employment for APK and Play Store distribution.

- 2026-09-05 â€” Replaced the duplicate date of birth under My Profile > Employment with Shift Timings.

- 2026-09-04 â€” Restored complete Hiring and Joining data visibility for the protected MD account while retaining position scopes for dedicated recruitment operators.

- 2026-09-04 â€” Added the seven-calendar-day attendance-blocking grace period for newly joined employees.
- 2026-09-04 â€” Added Chrome home-screen installation guidance for the red Attica admin icon.
- 2026-09-04 â€” Mapped Full Day Remote report entries to Work Visit source and Reviewed By attribution.
- 2026-09-04 â€” Fixed nested Regularization Report serial numbers and added evidence-based recovery of legacy reviewer names.
- 2026-09-04 â€” Added Head Office and state-wise filters plus resolved location details to the Regularization Report.
- 2026-09-04 â€” Added the MD-only monthly Regularization Report, employee ranking, per-admin counts, entry details, and legacy attribution message.
- 2026-09-04 â€” Changed Timing Report rankings to order regular employees by extra hours and irregular employees by missing scheduled hours.
- 2026-09-04 â€” Corrected Timing Report employee-name filter initialization so the MD report opens without an undefined-key error.
- 2026-09-04 â€” Added the MD-only Reports > Timing Report workflow, filters, shift-aware metrics, ranking rules, and tracked-day scope.
- 2026-09-03 â€” Documented readable Aadhaar, PAN, bank account, IFSC, and UAN values on the authenticated employee profile while retaining encrypted backend storage.
- 2026-09-03 â€” Restored CSR Manager / TL profile, theme customization, and password self-service controls.
- 2026-09-03 â€” Added Telecaller employees to CSR TL views and shift-timing management.
- 2026-08-01 â€” Version 5.0.22+5023 â€” Documented exact advance sidebar highlighting and the Account Details active/inactive employee filter.
- 2026-08-01 â€” Version 5.0.22+5023 â€” Documented the three separate Salary advance administration pages and their faster independent loading.

- 2026-09-18 - Documented that the Joining user can set Fixed Salary only before Employee ID assignment or mark-on-duty, after which it is read-only.
- 2026-08-01 â€” Version 5.0.22+5023 â€” Created the end-to-end user guide.

