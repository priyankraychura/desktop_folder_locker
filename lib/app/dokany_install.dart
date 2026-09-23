import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/di/core_providers.dart';
import '../core/theme/app_palette.dart';
import '../core/widgets/feedback.dart';
import '../engine/drive/drive_service.dart';
import '../platform/dokany_setup.dart';

/// Installs the Dokany that comes with the app (Windows asks for
/// administrator permission), says how it went, and returns the new status,
/// or `null` if nothing was installed.
Future<DokanyStatus?> installDokany(BuildContext context) async {
  // Outlives the widget, which may be gone when the setup finishes.
  final container = ProviderScope.containerOf(context, listen: false);
  final outcome = await container.read(dokanyInstallerProvider).install();
  switch (outcome.result) {
    case DokanySetupResult.cancelled:
      return null;
    case DokanySetupResult.failed:
      final details = outcome.logPath == null
          ? ''
          : ' Details are in ${outcome.logPath}.';
      showToast(
        'Dokany could not be installed (code ${outcome.code}).$details',
        tone: Tone.danger,
      );
      return null;
    case DokanySetupResult.installed:
      showToast(
        'Dokany is installed. Encrypted folders can open as drives now.',
        tone: Tone.success,
      );
    case DokanySetupResult.restartNeeded:
      showToast(
        'Dokany is installed. Restart Windows to finish, then open your '
        'drives.',
        tone: Tone.warning,
      );
  }
  container.invalidate(dokanyStatusProvider);
  try {
    return await container.read(dokanyStatusProvider.future);
  } on Object {
    return null;
  }
}
