import 'package:desktop_folder_locker/platform/dokany_setup.dart';

/// Stands in for Dokany's installer: "installs" by running [onInstall] and
/// reporting [outcome].
class FakeDokanyInstaller implements DokanyInstaller {
  @override
  bool isAvailable = false;

  DokanySetupOutcome outcome = const DokanySetupOutcome(
    DokanySetupResult.installed,
  );

  /// What installing changes, for example the fake helper's status.
  void Function()? onInstall;

  int installs = 0;

  @override
  Future<DokanySetupOutcome> install() async {
    installs++;
    if (outcome.result == DokanySetupResult.installed ||
        outcome.result == DokanySetupResult.restartNeeded) {
      onInstall?.call();
    }
    return outcome;
  }
}
