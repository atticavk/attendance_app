# Attica Attendance — Developer and Publication Guide

Last reviewed: 2026-08-01  
Documented version: 5.0.22 (build 5023)  
Repository: `atticavk/attendance_app`

## Scope

This guide covers setup, architecture, configuration, validation, Android signing, artifact production, publication, verification, rollback, and maintenance. Run commands from the repository root.

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

Most domain and UI logic currently lives in `lib/main.dart`; keep changes focused and test adjacent workflows carefully.

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
flutter pub get
flutter doctor -v
```

Never commit `.dart_tool`, `build`, local Gradle homes, IDE state, logs, screenshots, keystores, `key.properties`, credentials, or private data. Confirm `android/app/google-services.json` belongs to the intended Firebase project and application ID before release.

## Configuration

`ApiConfig` in `lib/main.dart` defaults to:

```text
https://atticagold.app/api
```

Override it without editing source:

```powershell
flutter run --dart-define=API_BASE_URL=https://example.internal/api
```

Android emulators reach a backend on the host through `10.0.2.2`, not `localhost`. The app normalizes Android loopback URLs and appends `/api` if absent. A previously persisted endpoint can override a newly compiled default, so reset it during endpoint testing.

Application metadata:

- Android ID/namespace: `app.abhibs.locatoremployee`
- Display name: `Attica Attendance`
- Current version: `5.0.22+5023` in `pubspec.yaml`
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

### Salary advance admin pages

The former combined admin advance screen is split into independently loaded routes:

| Page | Route name | Data loaded |
| --- | --- | --- |
| Import Advance | `admin-salary-advance-import-page` | Import form and session-based import results/conflicts |
| Advance Requests | `admin-salary-advance-requests` | Pending app requests and employee/bank details required for review |
| Add Advance Details | `admin-salary-advance` | Active employees, detail records, ledger counts, and aggregate totals |

POST actions redirect back to their owning page. Keep this separation when extending the module; do not reintroduce cross-page queries. The add-details query intentionally uses counts and SQL sums without eager-loading every historical transaction. Full history belongs on `admin-salary-advance-history`.

Existing custom sidebar permissions containing `salary.advance` are expanded at runtime to the two new advance menu keys for backward compatibility. Accounts-role defaults explicitly include all three.

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

Known backend baseline at this update: the filtered PHPUnit run stops before execution because `app/Support/AdvancePayrollWindow.php` declares `Tests\Unit\AdvancePayrollWindowTest`, colliding with the actual test class. Do not report the backend suite as passing until that class declaration issue is corrected.

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

## Documentation change log

- 2026-08-01 — Version 5.0.22+5023 — Documented the split Salary advance routes, query isolation, sidebar compatibility, performance behavior, redirects, and backend validation blocker.
- 2026-08-01 — Version 5.0.22+5023 — Created the end-to-end developer and publication guide.
