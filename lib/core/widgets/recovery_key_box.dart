import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../constants/app_info.dart';
import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import 'feedback.dart';

/// Shows the recovery key in large monospace groups with Copy and Save.
class RecoveryKeyBox extends StatelessWidget {
  const RecoveryKeyBox({required this.recoveryKey, super.key});

  final String recoveryKey;

  List<String> get _groups => recoveryKey.split('-');

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: recoveryKey));
    showToast(
      'Recovery key copied. Paste it somewhere safe, then clear your '
      'clipboard.',
      tone: Tone.success,
    );
  }

  Future<void> _save() async {
    final location = await getSaveLocation(
      suggestedName: '${AppInfo.name} recovery key.txt',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Text file', extensions: ['txt']),
      ],
    );
    if (location == null) return;
    await File(location.path).writeAsString(
      '${AppInfo.name} recovery key\n'
      '==============================\n\n'
      '$recoveryKey\n\n'
      'Created: ${DateTime.now()}\n\n'
      'Use this key to reset your master password or to open your locked\n'
      'items if you forget it. Keep it somewhere safe and private.\n',
    );
    showToast('Recovery key saved.', tone: Tone.success);
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    final mono = context.text.titleMedium?.copyWith(
      fontFamily: 'Consolas',
      fontFamilyFallback: const ['Cascadia Mono', 'Courier New', 'monospace'],
      letterSpacing: 1.5,
      fontWeight: FontWeight.w600,
    );
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: context.palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectionArea(
            child: Column(
              children: [
                for (var row = 0; row < groups.length; row += 4) ...[
                  if (row > 0) const SizedBox(height: AppSpacing.sm),
                  Row(
                    children: [
                      for (
                        var i = row;
                        i < row + 4 && i < groups.length;
                        i++
                      ) ...[
                        if (i > row) const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              vertical: AppSpacing.sm,
                            ),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: context.colors.surfaceContainerLowest,
                              borderRadius: BorderRadius.circular(AppRadius.sm),
                              border: Border.all(color: context.palette.border),
                            ),
                            child: Text(groups[i], style: mono),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _copy,
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: const Text('Copy'),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('Save to file…'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
