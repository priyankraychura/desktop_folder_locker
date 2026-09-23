import 'package:desktop_folder_locker/features/shell/application/launch_intents.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LaunchIntent.parse', () {
    test('reads --open and --lock', () {
      expect(
        LaunchIntent.parse(['--open', r'C:\Docs\Secret.flk']),
        isA<OpenVaultIntent>().having(
          (i) => i.path,
          'path',
          r'C:\Docs\Secret.flk',
        ),
      );
      expect(
        LaunchIntent.parse(['--lock', r'C:\Docs\Secret']),
        isA<LockPathIntent>().having((i) => i.path, 'path', r'C:\Docs\Secret'),
      );
    });

    test('reads --unlock', () {
      expect(
        LaunchIntent.parse(['--unlock', r'D:\Music']),
        isA<UnlockPathIntent>().having((i) => i.path, 'path', r'D:\Music'),
      );
      expect(
        LaunchIntent.parse(['--unlock', r'C:\Docs\Secret.flk']),
        isA<OpenVaultIntent>(),
      );
    });

    test('"lock" on a vault file means unlock it', () {
      expect(
        LaunchIntent.parse(['--lock', r'C:\Docs\Secret.FLK']),
        isA<OpenVaultIntent>(),
      );
      expect(
        LaunchIntent.parse(['--lock', r'C:\Docs\Photos.flkd']),
        isA<OpenVaultIntent>(),
      );
      expect(
        LaunchIntent.parse(['--open', r'C:\Docs\Photos.flkd\vault.flk']),
        isA<OpenVaultIntent>(),
      );
    });

    test('ignores unknown or incomplete arguments', () {
      expect(LaunchIntent.parse([]), isNull);
      expect(LaunchIntent.parse(['--open']), isNull);
      expect(LaunchIntent.parse(['--open', '  ']), isNull);
      expect(LaunchIntent.parse(['--other', 'x']), isNull);
    });
  });

  test('queue hands out the first intent that can be handled', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final intents = container.read(launchIntentsProvider.notifier)
      ..addArgs(['--lock', 'a'])
      ..addArgs(['--open', 'b.flk']);

    final first = intents.take((intent) => intent is OpenVaultIntent);
    expect(first, isA<OpenVaultIntent>());
    expect(container.read(launchIntentsProvider), hasLength(1));
    expect(intents.take((intent) => intent is OpenVaultIntent), isNull);
    expect(intents.take((_) => true), isA<LockPathIntent>());
    expect(container.read(launchIntentsProvider), isEmpty);
  });
}
