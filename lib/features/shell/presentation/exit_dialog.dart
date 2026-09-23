import 'package:flutter/material.dart';

import '../../../core/theme/app_palette.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_dialog.dart';
import '../../../core/widgets/icon_tile.dart';
import '../../items/domain/protected_item.dart';

enum ExitChoice { lockAllAndClose, closeAnyway }

/// Warns that some items are still unlocked before the app closes.
/// Returns `null` if the user cancels.
Future<ExitChoice?> showExitDialog(
  BuildContext context, {
  required List<ProtectedItem> unlocked,
}) => showDialog<ExitChoice>(
  context: context,
  builder: (context) {
    const maxShown = 4;
    final shown = unlocked.take(maxShown).toList();
    final more = unlocked.length - shown.length;
    return AppDialog(
      icon: Icons.lock_open_rounded,
      tone: Tone.warning,
      title: unlocked.length == 1
          ? '1 item is still unlocked'
          : '${unlocked.length} items are still unlocked',
      subtitle: 'Lock them again before closing?',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final item in shown)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Row(
                children: [
                  IconTile(
                    icon: item.kind == ItemKind.folder
                        ? Icons.folder_rounded
                        : Icons.insert_drive_file_rounded,
                    tone: Tone.warning,
                    size: 30,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      item.name,
                      style: context.text.bodyMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          if (more > 0) Text('and $more more…', style: context.text.bodySmall),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.of(context).pop(ExitChoice.closeAnyway),
          child: const Text('Close anyway'),
        ),
        FilledButton.icon(
          onPressed: () =>
              Navigator.of(context).pop(ExitChoice.lockAllAndClose),
          icon: const Icon(Icons.lock_rounded, size: 18),
          label: const Text('Lock all and close'),
        ),
      ],
    );
  },
);
