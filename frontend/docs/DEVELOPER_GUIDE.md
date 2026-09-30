# Attica Attendance - Developer and Publication Guide

Last reviewed: 2026-10-01
Documented version: 5.0.36 (build 5037)  
Repository: `atticavk/attendance_app`

## Scope

This guide covers the complete Flutter frontend and Laravel backend, setup, configuration, validation, Android signing, publication, rollback, and maintenance. The repository root now contains `frontend/`, `Backend/`, and `tools/`. Unless a command explicitly changes directories, run Flutter commands from `frontend/` and Artisan/Composer commands from `Backend/`.

## Complete repository and local bootstrap (2026-10-01)

The root [README](../../README.md) contains the clean-clone quick start. Source now includes the latest frontend (5.0.36+5037), Laravel application, admin/static assets, lockfiles, all migrations, and an initial migration for the previously external `employee` and `wp_branches_database` tables. No production data is included. Historical migrations no longer create accounts with shared passwords.

Install PHP 8.1/8.2 and Composer, local MySQL 8 or MariaDB 10.4+, and Flutter 3.44.8 (Dart 3.12.2). Java 17 and Android SDK are additionally needed for Android. `composer install --working-dir=Backend` uses the locked backend dependencies; missing PHP extensions are reported by Composer. Admin assets are included directly; the current Blade pages do not require a Vite build.

From the repository root, run `php tools/setup-local.php` after Composer installation. It creates a local `.env` from the template, verifies the environment and database name, prepares an empty local database, generates an application key, runs migrations, creates fictional demo data, and links storage. It refuses nonempty databases and does not drop tables. The default database is `attendance_local`; configure your own local MySQL username/password in `Backend/.env` before setup when necessary. The script is not a production installer or a restore command.

The underlying `php artisan attendance:setup-demo --yes` command only runs in local/testing environments with empty admin, employee, branch and employee-credential tables. It prints newly generated passwords once, stores hashes, and creates a fictional admin, branch and employee. To test attendance geofencing, initialize the demo with `--latitude` and `--longitude` matching your test location, or edit the demo branch through the admin panel. CI can supply temporary `ATTENDANCE_DEMO_ADMIN_PASSWORD` and `ATTENDANCE_DEMO_EMPLOYEE_PASSWORD` environment values; do not commit or log them.

Build the web frontend with `flutter build web --dart-define=API_BASE_URL=http://127.0.0.1:8000/api` in `frontend/`, then run `php artisan serve --host=127.0.0.1 --port=8000` in `Backend/`. Laravel serves the sibling `frontend/build/web` at `/`, its APIs at `/api`, and the admin login at `/admin/login`. A missing web build returns an actionable 503. Flutter tests run independently; MySQL is needed for the full application. Generated web output, vendor packages, caches, logs, release packages and uploads remain ignored.

Fresh frontend builds use a local API default. Always pass `--dart-define=API_BASE_URL=https://your-host.example/api` for production. Android emulators use `http://10.0.2.2:8000/api`; physical devices need the host LAN address and a reachable bind address. A previously saved endpoint can override the compiled default, so reset the endpoint/app data when changing environments.

Firebase push is opt-in through `--dart-define=ENABLE_FIREBASE_PUSH=true`, with your own platform configuration (`android/app/google-services.json` for Android) and backend Firebase project/service-account settings. The Android Google Services plugin is conditional on its configuration file. Core local login, admin, attendance and requests can be exercised without Firebase; remote push delivery cannot. SMS and employee sync require environment configuration; employee sync has no default production endpoint. The authenticated CARTO basemap needs `CARTO_API_KEY`. Scheduled notifications/SMS require a once-per-minute `php artisan schedule:run` scheduler; configure providers before enabling production jobs. Default mail delivery is the local log mailer.

VM password login requires `VM_LOGIN_PASSWORD`; a blank value disables that login. The optional legacy restricted HR email is configured with `LIMITED_HR_EMAIL` instead of embedding an account identifier in templates. Newly created administrators receive a generated password shown once to the authorized creator, without storing a plaintext password hint. Existing account restoration uses the private database.

### Restoring the existing production installation

The repo can create a clean installation. Recovering the current business state additionally requires independently secured backups:

1. Restore the current MySQL database and keep its original `APP_KEY` in the private production `.env`. Replacing that key makes encrypted employee bank/identity values unreadable. Preserve required DB, Firebase, SMS, map and sync settings, with `APP_ENV=production`, `APP_DEBUG=false`, and the correct HTTPS `APP_URL`.
2. Restore media from `Backend/storage/app/public`, any actual `Backend/public/storage` directory, `Backend/public/EmployeeDocuments`, `Backend/storage/id-cards`, and other upload locations used by your deployment. Recreate `public/storage` only after checking whether the old installation used a physical directory or a symlink. Never overwrite real media with an empty folder.
3. Restore private payroll configuration under `Backend/storage/app/private/`: `may-2026-pf-employees.json` and `pf-salary-overrides.json`, or configure `PF_EMPLOYEES_PATH`/`PF_SALARY_OVERRIDES_PATH`. Empty example structures are in `Backend/app/Support/data/`. Real employee/UAN allowlists and per-employee salary overrides are deliberately absent from Git; leaving these files absent changes legacy override-based payroll results. Restore and verify them before using production payroll.
   For an older source checkout, `php scripts/import-private-payroll.php /path/to/original/Backend` (from the new `Backend/`) imports those embedded legacy files into ignored private storage without executing the old PHP. It refuses existing destination files and prints no employee values. Keep the imported files in the private backup; an optional active-members CSV is copied only when it exists inside the old backend directory.
4. Run `composer install --no-dev --prefer-dist --optimize-autoloader`, review and run pending migrations after a database backup, set writable storage/cache permissions, and rebuild configuration/views. Do not run `setup-local.php`, demo provisioning, `migrate:fresh`, or generate a replacement key on restored production data. Legacy baseline migration checks for existing tables.
5. Build/deploy the Flutter web bundle or Android release with the production API URL, configure the scheduler, and verify login, employee profile, attendance, admin reports, media and enabled integrations. Restore the original private Android signing keystore and `key.properties` for compatible app updates. The debug signing fallback is for local verification only.

Use a web-server document root of `Backend/public` for the Laravel application; do not expose the repository root, `.env`, private storage or database backups. This source publication does not deploy changes to the live server.

### Repository validation

`composer validate --no-check-publish` validates the locked backend manifest. The publication checks use `php vendor/bin/phpunit --filter='SetupDemoTest|PrivateConfigurationTest|AdminCreationPasswordTest'` from `Backend/`: they migrate an empty test database, verify safe demo provisioning, exercise employee login/profile/history/salary/leave/notifications, admin login/dashboard/employee directory/attendance reports, generated administrator passwords and disabled optional integrations. SQLite test helpers emulate MySQL string functions used by the directory; the application itself uses MySQL/MariaDB.

The `.github/workflows/verify.yml` workflow bootstraps an empty MySQL 8 service, runs those checks, and performs Flutter dependency resolution, `flutter analyze --no-fatal-infos`, all Flutter tests and a local-API web build. Generated CI demo passwords are kept out of console output. The two existing informational browser-bridge analyzer messages remain; warnings and errors still fail CI. PHPUnit data providers now use PHPUnit 9-compatible annotations. A misplaced duplicate controller was removed from the published source to avoid a PSR-4 autoload warning.

The broader legacy backend suite remains partly failing: tests reference removed spreadsheet/security helpers and a removed encryption migration, and some payroll/mobile-control/security expectations differ from the latest application. These are recorded limitations, not successful checks. They are separate from the clean-install tests; review those business/security expectations before using their suite as a production release gate.

The ID-card soft-delete migration now creates replacement non-unique indexes before removing unique indexes, preserving the InnoDB employee foreign key. Each schema step is checked independently so a prior failure after adding `deleted_at` can recover. On an installation where the old migration failed, deploy this source and rerun pending migrations; do not manually delete the foreign key or its data. Rollback reinstates uniqueness before removing replacement indexes and will correctly fail if duplicate submissions must first be resolved.

## Architecture

This Flutter client provides authentication, employee profile/ID-card/bank/UAN workflows, camera and geolocation attendance, fraud and mock-location checks, attendance history, salary, leave/advance/site-visit requests, TE Tracker, branch operations, Firebase messaging, local reminders, background work, and server-controlled required updates.

| Path | Responsibility |
| --- | --- |
| `lib/main.dart` | Bootstrap, models, API client, services, state, and primary UI |
| `lib/web_desktop_attendance_stub.dart` | Non-web conditional attendance bridge |
| `lib/web_desktop_attendance_web.dart` | Browser attendance/location integration |
| `android/app/src/main/AndroidManifest.xml` | Permissions, activity, notification receivers |
| `android/app/build.gradle.kts` | Application ID, SDK values, signing selection |
| `android/app/google-services.json` | Native Android Firebase configuration |
| `pubspec.yaml` | Version, SDK, dependencies, assets, launcher icon |
| `test/` | Flutter tests |
| `docs/` | User and developer documentation |

The Laravel admin backend is maintained in the sibling `Backend/` directory. Salary advance administration is handled by `SalaryController`, `AdminMenu`, `routes/admin.php`, and `resources/views/admin/salary/advance_details.blade.php`.

The admin Branch Map in `Backend/resources/views/admin/branch/index.blade.php` uses Leaflet with `branchMapMinZoom = 5` on both `L.map` and the CARTO tile layer. Keep that floor when changing map fit/reset behavior so users cannot zoom out beyond the India-region overview.

### Employee directory Excel export

`GET /admin/employee/export` (`admin-employee-export`) is available to the same HR Admin/Sub HR roles as the employee directory. `Admin\\EmployeeController::export` writes an `.xlsx` workbook with PhpSpreadsheet. It accepts the directory's `tab`, `search`, `state`, `city`, and `branch` query parameters and exports every matching Active, Inactive, or Outsource employee, not merely the current 50-row page. It deliberately excludes the recruitment-only Newly Onboarded tab. The route is included in `EnforceCsrManagerAccess` so its route allowlist remains aligned with All Employees access.

The directory and its export accept `sort=employee_id|branch|designation|shift_timing` and `direction=asc|desc`; sorting is applied after the existing resolved-branch filters and before pagination. The directory table headings create/toggle these query parameters, while the filter form preserves them. The export reads the same query parameters, so its rows match the on-screen sort and filters. They also accept `status=active|blocked|inactive`. A blank database status is treated as Active; this status predicate runs with search and location filters before tab segmentation, count calculation, pagination, and export. `App\\Support\\ShiftTimingFormatter` is the standard 12-hour range formatter. It returns `HH:MM AM - HH:MM PM` and treats missing or invalid values as `09:30 AM - 07:00 PM`. Admin create/update, Excel imports, recruitment joining, directory/export display, and the employee profile API use it so new and updated records converge on the same value without a database migration.

`EmployeeController::attachLastLoginBranchDetails` prefers `employee.last_login_branch_id` and falls back to the latest attendance row's check-out branch, then its check-in branch. The attendance lookup keeps using the indexed `empId` column. Returned identifiers and branch-master lookup keys are trimmed and uppercased so legacy branch padding or casing does not hide a match. Branch and outsource-location metadata populate the name, city, and state; when no master row exists, the recorded branch ID becomes the display label. Keep the directory and XLSX export on this shared resolver.

Deploy this correction with `release/attica-employee-directory-branch-fallback-public_html-20260916.zip` (SHA-256 `B492E04173A7A3BA0454BA35384BB8B89099BBB9C90FF1C2CE7218EA7B7B6441`) at the Laravel root, following `release/EMPLOYEE_DIRECTORY_BRANCH_FALLBACK_DEPLOYMENT_20260916.md`. The archive replaces only `app/Http/Controllers/Admin/EmployeeController.php`; no migration, dependency install, or frontend build is required.

Deploy the production patch `release/attica-employee-directory-excel-export-public_html-20260916-v4.zip` (SHA-256 `DD82F4E31BD0A5C132FC0B1F25DB1EADD5B124DC373FF5FAFABDB7BA76677E45`) at the Laravel root and follow `release/EMPLOYEE_DIRECTORY_EXCEL_EXPORT_DEPLOYMENT_20260916.md`. No migration, Composer install, frontend build, or Flutter rebuild is required.

### Recruitment candidate visibility

`RecruitmentController::restrictedAdminPosition` applies exact normalized `position_applied_for` scoping only to dedicated `hiring` and `joining` roles. Elevated `md`, `hr_admin`, and `subhr` users must receive an unrestricted candidate query; otherwise an MD profile position such as `Managing Director` incorrectly produces empty Hiring and Joining lists. Keep this policy consistent across form-link counts, hiring lists, joining lists, candidate detail access, and other recruitment queries that call `applyCandidateAdminPositionFilter`. Regression coverage is in `tests/Unit/RecruitmentAdminVisibilityTest.php`.

`RecruitmentController::storeOnboarding` and `updateJoiningDecision` (the Mark Onboarded popup) permit the Joining user to set `RecruitmentCandidate::fixed_salary` only while `generated_emp_id` is blank and the candidate has not reached `STATUS_JOINED` (marked on duty). The Blade form mirrors this state with a read-only input, but the controller retains the stored value when the lock applies so a forged POST cannot bypass it. The recruitment fixed-salary value remains separate from `Employee::salary`: `markJoined` creates or updates employee identity, assignment, branch, shift, and status without changing `employee.salary`; post-creation employee-salary changes belong in `EmployeeController::update`.

The production patch is `release/attica-md-recruitment-visibility-public_html-20260904.zip` with SHA-256 `E660757E1C0284EC3CC25CD438ACD6332C4FA7B963BE5C650B93DF1548E35B05`. Extract it at the Laravel root and follow `release/MD_RECRUITMENT_VISIBILITY_DEPLOYMENT_20260904.md`. No migration or dependency/build step is required.

### CSR TL designation scope

`App\Support\CsrManagerScope::scopeEligibleEmployeeDesignation` is the single designation predicate for CSR TL access. It includes designations containing `CSR` and the case-insensitive, trimmed exact designation `TELECALLER`. The global employee scope, related employee-code scopes, branch scope, and CSR TL shift-timing update must all use this predicate so their visibility and authorization remain aligned.

CSR Manager / TL pages retain the `csr-manager-readonly` UI guard for operational write controls. Self-service forms must carry `data-csr-self-service-form`, which makes them visible without weakening the general read-only rule. `EnforceCsrManagerAccess` separately permits POST requests only for profile details, theme preferences, password changes, and the existing CSR shift-timing action. Keep the UI exemption and middleware allowlist aligned when adding another self-service setting. Focused coverage lives in `tests/Unit/CsrManagerProfileAccessTest.php`.

### Encrypted employee profile identifiers

`App\Casts\EncryptedString` is applied to `EmployeeDetail.bankAcNo`, `ifscCode`, `aadhaarNo`, `panNo`, and `uanNumber`, and to the corresponding pending fields on `EmployeeBankDetailRequest`. Values are encrypted before database persistence and decrypted by Eloquent when the authenticated profile API constructs or serializes its response. This keeps database-at-rest encryption intact while preventing Laravel ciphertext from appearing in Flutter. The cast temporarily reads legacy plaintext rows unchanged; deployment must preserve the existing `APP_KEY`, use HTTPS, and never log decrypted values. Regression coverage is in `tests/Unit/EncryptedEmployeeProfileFieldsTest.php`.

The production backend artifact is `release/attica-employee-profile-display-csr-profile-public_html-20260903.zip`. It also includes the CSR Manager / TL self-service profile fix. Follow `release/EMPLOYEE_PROFILE_DISPLAY_CSR_PROFILE_DEPLOYMENT_20260903.md`; no migration, Composer install, or Flutter rebuild is required.

The production-only deployment archive is `release/attica-csr-tl-telecaller-public_html-20260903.zip`. Extract it at the Laravel root and follow `release/CSR_TL_TELECALLER_DEPLOYMENT_20260903.md`; no migration, dependency install, or Flutter rebuild is required.

Most domain and UI logic currently lives in `lib/main.dart`; keep changes focused and test adjacent workflows carefully.

Attendance Reports consumes `AttendanceHistorySummary.singlePunchDays` as the finalized monthly single-punch total from the backend. `AttendanceController::historySummaryPayload` already excludes today's active Logout Pending session from that total, so the Flutter card must display `summary.singlePunchDays` directly. The Flutter report table synthesizes current-day pending rows client-side: if no record exists for today, it adds a `login_pending` row and subtracts the current pending day from the displayed Absent Days total; if today's record exists without check-out, `AttendanceRecord.isLogoutPendingToday` displays Logout Pending. The table/filter may still hide `record.isLogoutPendingToday` from the Single Punches drill-down while the current-day session is active.

`AttendanceController::checkIn` treats `empId + check_in_date` as the natural attendance key. A repeated check-in for the same employee/date updates the existing row with the latest branch, photo, location, time, distance, and submission ID, returning HTTP 200; a first check-in still returns HTTP 201. Migration `2026_09_22_000001_add_unique_employee_check_in_date_to_attendance_table.php` deduplicates existing attendance rows by keeping the latest `id`, filling any missing nullable values from older rows, deleting the older duplicates, and then adding unique index `attendance_emp_checkin_date_unique`. Keep future import or admin-created attendance paths aligned with this one-row-per-employee-date rule.

My Profile's Employment card displays `Employee.shiftTiming` using the existing `_stringOrFallback` handling for missing values. This field is already parsed from the profile API's `shiftTiming` property (backed by `Employee.shift_timing`); no API or database change is required. Date of birth remains in the personal profile section. A Flutter rebuild is required to deliver this UI change.

## Prerequisites and setup

- Git and authenticated repository access
- Flutter stable compatible with Dart `^3.11.0`
- Java 17 and Android SDK/Android Studio
- Device or emulator
- Matching backend and Firebase access
- Authorized release keystore for production

The documented environment used Flutter 3.44.8 and Dart 3.12.2.

```powershell
git clone https://github.com/atticavk/attendance_app.git
Set-Location attendance_app
Set-Location frontend
flutter pub get
flutter doctor -v
```

Never commit `.dart_tool`, `build`, local Gradle homes, IDE state, logs, screenshots, keystores, `key.properties`, credentials, or private data. Confirm `android/app/google-services.json` belongs to the intended Firebase project and application ID before release.

## Configuration

`ApiConfig` in `lib/main.dart` defaults to the local backend for fresh builds:

```text
http://127.0.0.1:8000/api
```

Override it without editing source:

```powershell
flutter run --dart-define=API_BASE_URL=https://example.internal/api
```

Android emulators reach a backend on the host through `10.0.2.2`, not `localhost`. The app normalizes Android loopback URLs and appends `/api` if absent. A previously persisted endpoint can override a newly compiled default, so reset it during endpoint testing.

Application metadata:

- Android ID/namespace: `app.abhibs.locatoremployee`
- Display name: `Attica Attendance`
- Current version: `5.0.36+5037` in `pubspec.yaml`
- Minimum Android API: at least 23 through Gradle configuration

Increase the build number for every published Android artifact; never reuse a version code.

## Development and validation

1. Work on an updated feature branch.
2. Make a focused change.
3. Update affected documentation and its change log in the same commit, following `AGENTS.md`.
4. Format, analyze, test, and build the relevant target.
5. Review the full diff for secrets and generated/local noise.
6. Push and open a reviewed pull request.

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub
flutter test
flutter build apk --debug
```

Known baseline at guide creation: analysis reports two informational web-library notices in `lib/web_desktop_attendance_web.dart` and two test compile errors in `test/widget_test.dart` because its mocked login callback uses the old signature. Fix these before claiming a clean validation run.

Test session changes across first login, remembered login, password setup, restore, logout, expiry, and upgrade. Test attendance changes across permission denial/recovery, offline behavior, location integrity, duplicate submission, early checkout, camera interruption, background location, and server rejection. Test notifications in foreground, background, terminated, after reboot, after token refresh, and after logout.

### New-joiner attendance-blocking grace period

`EmployeeAttendanceBlockService` selects `employee.doj` and applies a seven-calendar-day grace period starting on the DOJ. `attendanceBlockingStartsOn` returns DOJ plus seven days, so DOJ through DOJ+6 are protected. `syncEligibleEmployees`, `syncEmployee`, and `isBlocked` do not newly block an employee while `today` is before that start date.

The consecutive-absence calculation also removes dates earlier than the blocking start. It returns zero until three prior working dates exist after the grace period, preventing onboarding-period absences from immediately blocking the employee on day eight. Missing or invalid DOJ values retain the existing blocking behavior so legacy employees are not granted an indefinite exemption.

The production archive is `release/attica-attendance-block-joining-grace-public_html-20260904.zip` with SHA-256 `6E9A174E63C472A4C656E8E863E3A19169947941B9FC85B2B1CD718026323381`. Extract it at the Laravel root and follow `release/ATTENDANCE_BLOCK_JOINING_GRACE_DEPLOYMENT_20260904.md`.

Focused validation:

```powershell
Set-Location ..\Backend
php -l app/Services/EmployeeAttendanceBlockService.php
php artisan test tests/Feature/EmployeeAttendanceBlockServiceTest.php
php artisan test tests/Feature/AttendanceSubmissionConfirmationTest.php
php artisan test tests/Feature/EmployeeInactiveAccessTest.php
```

### Salary advance admin pages

The former combined admin advance screen is split into independently loaded routes:

| Page | Route name | Data loaded |
| --- | --- | --- |
| Import Advance | `admin-salary-advance-import-page` | Import form and session-based import results/conflicts |
| Advance Requests | `admin-salary-advance-requests` | Pending app requests and employee/bank details required for review |
| Add Advance Details | `admin-salary-advance` | Active employees, detail records, ledger counts, and aggregate totals |

POST actions redirect back to their owning page. Keep this separation when extending the module; do not reintroduce cross-page queries. The add-details query intentionally uses counts and SQL sums without eager-loading every historical transaction. Full history belongs on `admin-salary-advance-history`.

Existing custom sidebar permissions containing `salary.advance` are expanded at runtime to the two new advance menu keys for backward compatibility. Accounts-role defaults explicitly include all three.

The sidebar uses exact route matching for the three advance pages so the shared `admin-salary-advance` prefix cannot activate **Add Advance Details** while **Advance Requests** or **Import Advance** is open. Advance-history routes intentionally activate **Add Advance Details**.

Account Details accepts a normalized `status` query filter of `active` or `inactive`. Active means the employee status is null or is not `inactive` after trimming/case normalization; inactive means it equals `inactive`. The same filter pipeline supplies the HTML page and Excel export, so exports preserve the selected status together with name, branch, and state.

Backend validation commands:

```powershell
Set-Location ..\Backend
php -l app/Http/Controllers/Admin/SalaryController.php
php -l app/Support/AdminMenu.php
php -l routes/admin.php
php artisan route:list --name=admin-salary-advance
php artisan view:cache
php artisan test --filter=Advance
```

Known backend baseline at this update: the full unit suite still has unrelated failures in legacy spreadsheet support, data-provider discovery, employee-directory test setup, and older security expectations. Use the focused commands below for this feature, and do not report the complete backend suite as passing until those baseline failures are corrected.

### Admin timing report

The `admin-attendance-timing-report` route serves **Reports > Timing Report** through `AttendanceManagementController::timingReport`. The route is inside the `admin.role:md` group. Its `reports.timing` menu key is mapped by `AdminMenu`, but `AdminMenu::adminCanSee` explicitly requires the normalized `md` role. This role gate overrides full-menu and saved custom-menu selections, preventing HR, zonal, CSR Manager / TL, accounts, and other roles from seeing or opening the page.

The cumulative production deployment artifact is `release/attica-md-timing-regularization-reports-public_html-20260904.zip` with SHA-256 `9B16B7E8EF836825E988FCE718A118E43C56C0AF7739EA3206E65FC20AE71741`. Extract it at the Laravel application root and follow `release/MD_REPORTS_DEPLOYMENT_20260904.md`. It supersedes the earlier Timing Report-only archive and includes both MD reports, the HO/state Regularization Report filters, legacy reviewer recovery, Work Visit reviewer attribution, the nested-table serial fix, and the additive regularization-actor migration. It requires `php artisan migrate --force` and cache refresh, but no Composer install, frontend build, or Flutter rebuild.

The controller applies the standard attendance-report month/date, scope, location, employee ID, and employee-name filters. It excludes inactive and outsourced employees, loads effective-dated shift histories, and supplies app attendance plus imported HO daily summaries to `AttendancePunctualityService`. When both sources exist for one employee/date, imported HO timing takes precedence, matching the existing punctuality dashboard behavior.

`AttendancePunctualityService::analyzeEmployee` also returns `expected_seconds`, `worked_seconds`, capped `hours_completion_percent`, total late/early minutes, and event-day average late/early minutes. Expected seconds are the sum of the effective shift duration for tracked dates only. Worked seconds use imported `logged_seconds` when available, otherwise derive duration from first/last punches; app duration uses its dated check-in and check-out. Overnight ranges roll into the next day. The controller derives `extra_hours_seconds = max(worked - expected, 0)` and `hours_shortfall_seconds = max(expected - worked, 0)`. `TimingReportRanking` limits both lists to 10: regular rows have no shortfall and sort by extra seconds descending; irregular rows have a positive shortfall and sort by shortfall seconds descending. Irregular days and average late/early minutes are tie-breakers.

Focused validation:

```powershell
Set-Location ..\Backend
php artisan test tests/Unit/AttendancePunctualityServiceTest.php
php artisan test tests/Unit/TimingReportAccessTest.php
php artisan test tests/Unit/TimingReportRankingTest.php
php artisan route:list --name=admin-attendance-timing-report
php artisan view:cache
```

### Admin Chrome home-screen icon

The admin login and shared authenticated layout link `public/attica-manifest.json` through `ProjectAsset::url`, supporting deployments where the Laravel `public` directory is either the document root or a subdirectory. The manifest uses `/admin/dashboard` as its relative start URL, `/admin/` scope, standalone display, and Attica red `#760107` for background/theme colors.

The icon files under `public/admin/assets/images` are deterministic sizes derived from the existing official `attica_favicon.png`: 192x192 and 512x512 `any` icons, a 512x512 `maskable` icon with safe-area padding, and a 180x180 Apple touch icon. Both Blade heads provide manifest, theme-color, mobile-web-app, and Apple metadata. Chrome may retain an installed shortcut's old icon, so post-deployment verification must remove and recreate any existing test shortcut.

The production archive is `release/attica-chrome-home-icon-public_html-20260904.zip` with SHA-256 `D80FB67580D80CBD4A0FA011F37873282826F706549A7C93D38A75A0F7CE1318`. Extract it at the Laravel root and follow `release/CHROME_HOME_ICON_DEPLOYMENT_20260904.md`.

Focused validation:

```powershell
Set-Location ..\Backend
php artisan test tests/Unit/AdminHomeScreenManifestTest.php
php artisan view:cache
```

### Admin regularization report

The `admin-attendance-regularization-report` route serves **Reports > Regularization Report** through `AttendanceManagementController::regularizationReport`. It is registered inside the `admin.role:md` group, and the `reports.regularization` menu key has the same explicit MD-only check as Timing Report. Non-MD users cannot reveal it through full-menu or saved sidebar permissions.

The selected `YYYY-MM` month is converted to its calendar boundaries. The normalized `location` filter accepts `all`, `ho`, or `state:<state name>`; state values must match a known branch state. The report resolves location per employee/date from the attendance record, then the employee's assigned branch as fallback. HO-import records are explicitly classified as Head Office. Head Office is excluded from state selections even when the HO branch has the selected state.

The report reads regularized statuses from `attendance_day_overrides`, direct `attendance.attendance_status_override` values, and `ho_attendance_import_overrides`. Location filtering is applied to individual events before totals are grouped, so employees who change locations are counted correctly. Records are keyed by employee ID and attendance date so a day is counted once. Source precedence matches attendance calculation: calendar override, direct attendance override, then HO-import override. Rows are grouped by employee and sorted by regularization count descending, then employee name and ID.

Migration `2026_09_04_000001_add_regularized_by_to_attendance_table.php` adds nullable `attendance.attendance_status_override_by`. Attendance Review, Out of Office, and approved Work Visit writes now save an administrator name/email snapshot in this column. Existing calendar overrides retain admin IDs and HO-import overrides retain their existing actor strings; the report resolves numeric admin IDs to current admin names. Blank historical direct-override actors display `Not recorded (legacy)`.

For a blank legacy direct actor, `recoverLegacyRegularizationActors` looks for an `Attendance Regularization Updated` notification delivered to the same employee within 15 minutes of the attendance row update. The notification must explicitly contain the attendance date or a date range covering it, and its non-null `sent_by` admin ID is then resolved normally. This bounded employee/date/time match avoids guessing. The main Blade table intentionally omits `data-admin-static-serial`; it renders its own Rank column and therefore prevents the global serial script from modifying nested detail rows.

Before legacy recovery, `applyWorkVisitReviewers` classifies every `full_day_remote` event as `Work Visit`. It finds an approved `site_visit_requests` record by linked `attendance_id`, falling back to employee ID plus visit date, and replaces the report actor with the request's `reviewed_by` value when present. New Work Visit attendance snapshots use the same email-first reviewer representation as `reviewed_by`.

Focused validation:

```powershell
Set-Location ..\Backend
php artisan test tests/Feature/RegularizationReportTest.php
php artisan test tests/Unit/TimingReportAccessTest.php
php artisan route:list --name=admin-attendance-regularization-report
php artisan view:cache
```

## API and data safety

`EmployeeApiClient` owns HTTP calls and response mapping. API changes require matching model/error handling, tests, documentation, and backend compatibility review. Never log passwords, tokens, bank details, personal data, or attendance images.

The manifest requests camera, coarse/fine location, internet, notifications, boot completion, exact alarms, vibration, and foreground-service access. Permission changes require least-privilege review, denial behavior, user-guide/privacy updates, and store data-safety review.

`android:usesCleartextTraffic="true"` currently supports HTTP development endpoints. Review whether production can disable or narrowly constrain it.

## Android release signing

Production builds require the authorized keystore. Create `android/key.properties` locally:

```properties
storePassword=REDACTED
keyPassword=REDACTED
keyAlias=AUTHORIZED_ALIAS
storeFile=C:/secure/path/to/attendance-upload.jks
```

Gradle uses release signing when this file exists and otherwise falls back to debug signing. Never publish the fallback build. Do not commit the keystore or properties file, and do not expose credentials in logs.

## Pre-release checklist

- [ ] Product/release scope approved and release notes prepared.
- [ ] Version and build increased in `pubspec.yaml`.
- [ ] User/developer guides and change logs updated.
- [ ] Production API and Firebase configuration verified.
- [ ] No secrets, local endpoints, overrides, logs, screenshots, or caches staged.
- [ ] Formatting, analysis, tests, debug build, and release build pass, or exceptions are explicitly approved.
- [ ] Login/logout/session/update flows tested.
- [ ] Attendance, camera, location, denial recovery, integrity, and offline cases tested.
- [ ] Notifications tested across app lifecycle and reboot.
- [ ] Affected employee-service pages smoke-tested.
- [ ] Production application ID and signing certificate verified.
- [ ] Privacy/data-safety declarations reviewed.
- [ ] Rollback build and responsible operators identified.

## Build artifacts

### Android 5.0.36 (build 5037)

The 2026-09-22 Android release uses the existing production API default and configured release keystore. Versioned deliverables are placed in the workspace's sibling `release/` directory as `attica-attendance-5.0.36-5037-release.apk` and `attica-attendance-5.0.36-5037-release.aab`. Use the APK for approved direct installation and the AAB for Play Console upload. This build includes Attendance Reports fixes for finalized Single Punches totals, current-day Login Pending before check-in, and current-day Logout Pending after check-in until check-out.

SHA-256:

- `attica-attendance-5.0.36-5037-release.apk`: `56AED629847CDD32D92E8421EA514B407C48CC48D304168E2B50859A3E5F2A83`
- `attica-attendance-5.0.36-5037-release.aab`: `2DB6FE3D0B61CA9A10FFD0F3A4F3212F0A700AEEC61500AF82BFEED58AC782B5`

### Android 5.0.35 (build 5036)

The 2026-09-05 Android release uses the existing production API default and configured release keystore. Versioned deliverables are placed in the workspace's sibling `release/` directory as `attica-attendance-5.0.35-5036-release.apk` and `attica-attendance-5.0.35-5036-release.aab`. Use the APK for direct installation and the AAB for Play Console upload. Both include Shift Timings under My Profile > Employment; no backend deployment is needed for that display change.

Validation: all 13 Flutter tests passed. Full Flutter analysis reports only the two existing informational notices in `lib/web_desktop_attendance_web.dart` about deprecated `dart:html` and web-only libraries. Device smoke tests and Play Console upload validation must be performed before rollout. Release checksums and packaging verification are recorded alongside the artifacts.

```powershell
flutter clean
flutter pub get
flutter build appbundle --release
```

The Play/managed-distribution artifact is:

```text
build/app/outputs/bundle/release/app-release.aab
```

For an approved direct APK channel only:

```powershell
flutter build apk --release
```

Output:

```text
build/app/outputs/flutter-apk/app-release.apk
```

Record commit, version/build, environment, signing certificate fingerprint, publisher, validation, and artifact SHA-256:

```powershell
Get-FileHash build/app/outputs/bundle/release/app-release.aab -Algorithm SHA256
```

### Web release build

The 2026-09-03 production web artifact is `release/attica-attendance-5.0.34+5035-web-20260903.zip`. It was compiled in release mode from version `5.0.34+5035`. The deployable `index.html` uses `<base href="./">` to match the existing production package and support root or subdirectory hosting. Flutter 3.44 rejects `./` as a `--base-href` argument, so build normally and update only the generated `build/web/index.html` base element before packaging. Follow `release/WEB_BUILD_DEPLOYMENT_20260903.md` for deployment, cache refresh, verification, and rollback.

## Publish source and Android release

Publish source with explicit staging when the worktree is mixed:

```powershell
git status -sb
git diff --check
git add <explicit-paths>
git commit -m "Describe the release change"
git push -u origin <branch>
gh pr create --draft --base main --head <branch> --fill
```

Require review and checks before merge, then tag the exact approved release commit using the team's version convention.

For Android distribution:

1. Build and hash the production-signed AAB.
2. Upload to the approved Play Console track or enterprise portal.
3. Add user-facing release notes and complete policy declarations.
4. Release to an internal/closed test track first.
5. Install from that actual track and run post-publication checks.
6. Promote gradually while monitoring authentication, attendance, notification, and crash/error signals.

Portal, signing, and production access must follow least privilege and organizational approval.

## Post-publication verification

1. Install/update from the real channel and confirm version/build.
2. Test clean sign-in, session restoration, dashboard, profile, and logout.
3. With an approved test account/location, verify check-in/out, camera, location, and permission recovery.
4. Verify push messages and attendance/branch reminders in relevant lifecycle states.
5. Smoke-test salary, reports, requests, ID Card, and TE Tracker according to permissions.
6. Review backend and crash monitoring without exposing personal data.

## Rollback and incidents

Mobile releases cannot be removed instantly from devices. For a critical defect:

1. Pause rollout and notify product, backend, support, security, and release owners.
2. Mitigate the affected server capability when safe.
3. Revert or fix from the last known-good tag without rewriting shared history.
4. Increase the build number, rebuild, validate, and publish a corrective release.
5. Use server-driven required update only with approval and a reachable trusted URL.
6. Document timeline, affected versions, data impact, remediation, and follow-up tests.

Never roll back with an unsigned, debug-signed, or lower-version-code build.

## Documentation maintenance

- User-visible behavior, permissions, messages, requirements, or support: update `docs/USER_GUIDE.md`.
- Architecture, setup, API, dependencies, tests, build, security, deployment, or operations: update this guide.
- Cross-cutting changes: update both.
- Add a dated change-log entry to each affected guide.
- If genuinely unaffected, state `Documentation impact: none` with the reason in the commit or PR description.

Reviewers should reject changes whose documentation no longer matches implementation.

## Employee inactive audit

Employee inactive POST handlers save an allowlisted snapshot of the authenticated admin (`admin_id`, `name`, optional `empId`, and `role`) in nullable JSON `employee.marked_inactive_by`. The value comes from the admin guard, never request input; missing authentication is rejected. The Employee model casts it to an array and hides it from general serialization. Reactivation retains the latest snapshot; a subsequent inactive action replaces it. Existing records remain null. Deploy migration `2026_09_17_000001_add_marked_inactive_by_to_employee_table.php` with `php artisan migrate --force` from `Backend/` before enabling the updated controllers. No Flutter rebuild is required.

## Documentation change log

- 2026-10-01 - Combined the latest Flutter and Laravel source in a monorepo; added empty-database legacy schema bootstrap, guarded demo provisioning, local setup, safe environment templates, private payroll import, generated admin passwords, optional Firebase/integrations, and production restore instructions. Removed real personnel fixtures and embedded account secrets from published source. Validation results are recorded with the repository release.

- 2026-09-22 - Documented Attendance Reports current-day pending row handling and the direct backend-provided `singlePunchDays` display.

- 2026-09-22 - Increased Android version to 5.0.36+5037 for release APK/AAB builds containing the Attendance Reports pending-state and Single Punches fixes.

- 2026-09-17 - Documented automatic operator attribution when marking employees inactive.

- 2026-09-16 â€” Packaged the employee-directory branch fallback production patch and added deployment, verification, rollback, contents, and SHA-256 instructions.

- 2026-09-16 â€” Hardened employee-directory branch resolution for trimmed/case-varied branch IDs, check-out-only attendance records, and missing branch master labels; added regression coverage.

- 2026-09-16 â€” Added employee-directory sorting and the shared shift timing formatter/default across employee entry, import, recruitment, directory/export, and profile API workflows.

- 2026-09-16 â€” Added the All Employees status filter and applied it consistently to pagination, counts, sorting, and XLSX export.

- 2026-09-16 â€” Replaced the employee-directory sort selector with clickable sortable headings and persisted ascending/descending direction into XLSX downloads.

- 2026-09-16 â€” Added the filtered All Employees `.xlsx` export route, workbook fields, authorization allowlist entry, and user workflow.

- 2026-09-16 â€” Packaged the All Employees Excel export production patch and added deployment, verification, and rollback instructions.


- 2026-09-18 - Packaged `release/attica-joining-fixed-salary-lock-public_html-20260918.zip` for direct extraction into `public_html`; SHA-256 `817DCA55D2616D07CFB0245DA413D3DB1DEB3C79097AD16FD3E12631ACDB761B`. Deployment, verification, and rollback instructions are in `release/JOINING_FIXED_SALARY_LOCK_DEPLOYMENT_20260918.md`.

- 2026-09-18 - Documented the pre-Employee-ID/pre-mark-on-duty Joining Fixed Salary rule and its server-side enforcement.
- 2026-09-11 - Packaged `release/attica-carto-map-public_html-20260911.zip` for extraction directly into the production Laravel root at `public_html`. The archive contains only `config/services.php` and `resources/views/admin/branch/index.blade.php`, without a Backend wrapper or environment file. Back up those production files before extracting. Set CARTO_API_KEY in the existing production .env, then run `php artisan config:cache` and `php artisan view:clear` from public_html. Without terminal access, remove only `bootstrap/cache/config.php` if present to discard stale configuration; Blade normally recompiles the updated view on request. Verify the branch map after refreshing. Rollback restores the backed-up files and rebuilds configuration/clears views.

- 2026-09-11 - Replaced the admin branch map's two unauthenticated CARTO light layers with one authenticated Voyager raster layer in `Backend/resources/views/admin/branch/index.blade.php`. Set `CARTO_API_KEY` in the deployed backend environment; `config/services.php` exposes it as `services.carto.api_key`, serialized with Blade `@json` and URL-encoded for tile requests. The key is browser-visible by design; use a basemap key, never a server secret. Deploy the view and service configuration, set the environment value, then run `php artisan config:clear` (or rebuild the config cache) and `php artisan view:clear`. Reload the branch map and verify tile requests include the key and show no API-key watermark. No database migration or frontend rebuild is required. The environment template contains only an empty placeholder.

- 2026-09-05 â€” Increased Android version to 5.0.35+5036 for release APK/AAB builds containing the Employment shift timings display.

- 2026-09-05 â€” Bound My Profile > Employment's Shift Timings entry to the existing employee model/API field, replacing the duplicate date of birth.

- 2026-09-04 â€” Limited recruitment position scoping to dedicated Hiring/Joining roles, restored MD/HR/Sub HR full-data visibility, and added focused regression coverage.

- 2026-09-04 â€” Documented the seven-day new-joiner blocking exemption, post-grace absence counting, and focused regression tests.
- 2026-09-04 â€” Documented the admin web manifest, red Attica home-screen icon set, metadata, validation, and Chrome cache behavior.
- 2026-09-04 â€” Documented Full Day Remote classification and Work Visit Reviewed By attribution.
- 2026-09-04 â€” Documented the nested-table serial fix and bounded notification-based recovery of legacy regularization actors.
- 2026-09-04 â€” Documented per-day Head Office/state filtering and location resolution for the Regularization Report.
- 2026-09-04 â€” Documented the MD-only Regularization Report route, monthly aggregation and ordering, source precedence, actor tracking migration, deployment, and focused tests.
- 2026-09-04 â€” Changed Timing Report ranking to use extra worked hours for regular employees and scheduled-hours shortfall for irregular employees.
- 2026-09-04 â€” Added defensive Timing Report employee-name filter initialization and regression coverage.
- 2026-09-04 â€” Added the MD Timing Report production archive, deployment verification, and rollback procedure.
- 2026-09-04 â€” Documented the MD-only Timing Report route/menu authorization, data sources, effective-date shift calculations, metrics, ranking rules, and focused validation.
- 2026-09-03 â€” Documented Eloquent decryption of authorized employee profile identifiers, encrypted-at-rest behavior, compatibility handling, and regression coverage.
- 2026-09-03 â€” Documented CSR Manager / TL self-service form visibility, POST-route authorization, and focused regression coverage.
- 2026-09-03 â€” Documented and packaged the version 5.0.34+5035 production web release with relative-path hosting and deployment verification.
- 2026-09-03 â€” Documented the production-only CSR TL Telecaller deployment archive, verification, and rollback procedure.
- 2026-09-03 â€” Centralized the CSR TL designation predicate and documented Telecaller visibility, related-record scoping, shift-update authorization, and focused unit coverage.
- 2026-08-01 â€” Version 5.0.22+5023 â€” Documented exact advance-menu route matching and Account Details status filtering/export behavior.
- 2026-08-01 â€” Version 5.0.22+5023 â€” Documented the split Salary advance routes, query isolation, sidebar compatibility, performance behavior, redirects, and backend validation blocker.
- 2026-08-01 â€” Version 5.0.22+5023 â€” Created the end-to-end developer and publication guide.

