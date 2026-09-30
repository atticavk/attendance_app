# Attica Attendance

Flutter employee attendance and services application for Android, web, and supported desktop targets.

## Documentation

- [User guide](docs/USER_GUIDE.md): installation, sign-in, attendance, employee workflows, permissions, troubleshooting, privacy, and support.
- [Developer and publication guide](docs/DEVELOPER_GUIDE.md): setup, architecture, configuration, testing, signing, publication, verification, rollback, and maintenance.
- [Repository instructions](AGENTS.md): mandatory documentation updates for every change.

Current application version: `5.0.36+5037`.

This directory is the frontend of the complete application repository. Follow the [root quick start](../README.md) to set up the sibling Laravel backend and a clean local database first. Fresh builds use the local API; production builds need an explicit `API_BASE_URL`. Firebase push is optional and disabled until configured.

## Quick start

```powershell
flutter pub get
flutter analyze --no-pub
flutter test
flutter run
```

Read the developer guide before configuring production services or creating a release.
