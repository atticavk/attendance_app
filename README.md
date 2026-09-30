# Attica Attendance

Complete source for the Flutter employee app (5.0.36, build 5037) and Laravel API/admin panel. The maintained guides are [User Guide](frontend/docs/USER_GUIDE.md) and [Developer Guide](frontend/docs/DEVELOPER_GUIDE.md).

## Requirements

- PHP 8.1 or 8.2 with Composer 2 and the extensions required by `Backend/composer.lock` (including PDO MySQL, mbstring, XML, GD, zip and fileinfo).
- MySQL 8 or MariaDB 10.4+, running locally for the quick start.
- Flutter 3.44.8 / Dart 3.12.2 (the verified toolchain).
- Android SDK and Java 17 to build Android. A browser is sufficient for the web app/admin panel.

## Run locally from a clean clone

```sh
git clone https://github.com/atticavk/attendance_app.git
cd attendance_app
composer install --working-dir=Backend
php tools/setup-local.php
cd frontend
flutter pub get
flutter build web --dart-define=API_BASE_URL=http://127.0.0.1:8000/api
cd ../Backend
php artisan serve --host=127.0.0.1 --port=8000
```

Start MySQL before setup. The script creates `Backend/.env` from the example and an empty `attendance_local` database using local MySQL credentials. If your MySQL account needs a password, copy `Backend/.env.example` to `Backend/.env`, edit `DB_USERNAME`/`DB_PASSWORD`, then run the setup script. It refuses non-local connections and nonempty databases, and never drops a database. On a failed initial migration, repair the cause and use a new empty database name beginning `attendance_local` for another clean attempt.

Open the employee app at **http://127.0.0.1:8000/** and the admin login at **http://127.0.0.1:8000/admin/login**. Setup prints generated demo login credentials once; save them privately. The demo contains synthetic employees and branch data, with no real attendance/payroll records. Camera and location workflows require supported hardware, browser/device permissions and an appropriate branch location. Use HTTPS for remote devices.

## Android

With the backend running, open another terminal:

```sh
cd frontend
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000/api
```

`10.0.2.2` reaches the host from an Android emulator. For a physical phone, use the computer's LAN IP, bind the backend to `0.0.0.0`, and permit access through the local firewall. Release builds require your private signing key and `frontend/android/key.properties`; see the developer guide. Always pass the intended production API URL when building for deployment.

## Optional integrations and production restore

Core local setup does not require Firebase, an SMS provider, a payroll source file, or access to the production server. Firebase push must be explicitly enabled and configured; SMS, external employee sync and the authenticated CARTO basemap need your own settings. Their environment placeholders are in `Backend/.env.example`. This repository does not grant access to those services.

To restore the existing production business, also restore a current private database backup, uploaded files, the original Laravel `APP_KEY` and other environment secrets, payroll override files, and Android signing material. **Do not run the demo setup against a production database.** Detailed paths, restore ordering and scheduler requirements are in the developer guide. No real employee data, production credentials or signing keys belong in Git.

## Validation

```sh
composer validate --working-dir=Backend --no-check-publish
cd frontend
flutter analyze --no-fatal-infos
flutter test
```

The clean-install backend tests are `php vendor/bin/phpunit --filter='SetupDemoTest|PrivateConfigurationTest|AdminCreationPasswordTest'` from `Backend/`. They cover migrations, demo employee/admin login, profile and core pages, and configuration isolation. GitHub Actions runs these checks and the Flutter tests/web build. The older full backend suite still contains failing expectations for removed legacy security/spreadsheet code and changed payroll behavior; it is not a passing release gate. Flutter analysis currently has two informational messages in the legacy browser bridge; `--no-fatal-infos` keeps errors and warnings fatal. Dependency caches, generated builds and media backups are intentionally regenerated or restored separately.
