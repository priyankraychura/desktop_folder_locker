import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../engine/crypto/crypto_service.dart';
import '../../engine/crypto/kdf_params.dart';
import '../../engine/drive/drive_helper.dart';
import '../../engine/drive/drive_service.dart';
import '../../engine/engine_runner.dart';
import '../../platform/access_control.dart';
import '../../platform/dokany_setup.dart';
import '../../platform/system_tray.dart';
import '../storage/app_paths.dart';

/// App folder locations. Overridden in `bootstrap()` (and in tests).
final appPathsProvider = Provider<AppPaths>(
  (ref) => throw UnimplementedError('appPathsProvider must be overridden'),
);

/// libsodium for the UI isolate. Overridden in `bootstrap()`.
final cryptoProvider = Provider<CryptoService>(
  (ref) => throw UnimplementedError('cryptoProvider must be overridden'),
);

/// Password hashing cost. Tests override this with [KdfPolicy.fast].
final kdfPolicyProvider = Provider<KdfPolicy>((ref) => KdfPolicy.standard);

/// Path of the running executable (for Explorer integration and the
/// protected-location checks).
final executablePathProvider = Provider<String>(
  (ref) =>
      throw UnimplementedError('executablePathProvider must be overridden'),
);

/// Environment variables (used to find system folders that must not be
/// locked). Tests override it so temporary folders are allowed.
final environmentProvider = Provider<Map<String, String>>(
  (ref) => Platform.environment,
);

/// Whether the app runs in a real desktop window it controls (custom title
/// bar, close confirmation). Overridden to `true` in `bootstrap()`; widget
/// tests keep it `false`.
final nativeWindowProvider = Provider<bool>((ref) => false);

final engineRunnerProvider = Provider<EngineRunner>(
  (ref) => EngineRunner(ref.watch(cryptoProvider)),
);

/// Windows permission rules (Block access and Read-only). Tests use a fake.
final accessRulesProvider = Provider<AccessRules>(
  (ref) => const SystemAccessRules(),
);

/// The notification-area icon. Overridden with the native one on Windows
/// in `bootstrap()`.
final systemTrayProvider = Provider<SystemTray>((ref) => const NoSystemTray());

/// The drive helper, which encrypts folders into drive vaults and opens
/// them as drives. It starts on first use and stops with the app (which
/// closes every drive). Tests use a fake.
final driveServiceProvider = Provider<DriveService>((ref) {
  final service = HelperDriveService(HelperDriveService.defaultExecutable());
  ref.onDispose(service.dispose);
  return service;
});

/// Whether vaults can open as drives (Dokany is installed). Fails when the
/// drive helper is missing. Invalidate it to check again.
final dokanyStatusProvider = FutureProvider<DokanyStatus>(
  (ref) => ref.watch(driveServiceProvider).status(),
);

/// Installs the Dokany that comes with the app. Tests use a fake.
final dokanyInstallerProvider = Provider<DokanyInstaller>(
  (ref) => BundledDokanyInstaller(p.dirname(ref.watch(executablePathProvider))),
);
