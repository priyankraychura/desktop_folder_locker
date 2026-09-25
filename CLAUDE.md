# Notes for Claude

## Bump the version with every change

Every change to the app (code, UI, a bug fix, an update) bumps the version,
so a new build is easy to tell apart. Pick the part by how big the change
is:

- **patch** (1.3.0 → 1.3.1): small fixes and tweaks;
- **minor** (1.3.0 → 1.4.0): new features, or fixes that change behavior;
- **major** (1.3.0 → 2.0.0): big redesigns, or changes that break vaults or
  settings.

Always increase the build number after the `+` in `pubspec.yaml` by one.

The version is in all of these places, which must match:

- `pubspec.yaml` (`version: X.Y.Z+N`);
- `lib/core/constants/app_info.dart` (`AppInfo.version`);
- `installer/cloak.iss` (`AppVersion`, twice);
- `native/Cargo.toml` (`[workspace.package] version`), then
  `cargo update -w` in `native/` to update `Cargo.lock`;
- the examples in `README.md`, `installer/msix/build-msix.ps1` and
  `installer/sparse/build-package.ps1`.
