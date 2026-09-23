import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../engine/crypto/crypto_service.dart';
import '../../engine/crypto/kdf_params.dart';
import '../../engine/engine_runner.dart';
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
