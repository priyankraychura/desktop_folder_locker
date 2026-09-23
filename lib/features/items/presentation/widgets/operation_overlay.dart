import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_palette.dart';
import '../../../../core/theme/app_tokens.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/icon_tile.dart';
import '../../../../engine/operations/operation_progress.dart';
import '../../application/protection_controller.dart';

/// Covers the whole window with a progress card while an item is being
/// locked or unlocked. Sits above every page and dialog.
class OperationOverlay extends ConsumerWidget {
  const OperationOverlay({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final operation = ref.watch(protectionControllerProvider);
    return Stack(
      children: [
        child,
        Positioned.fill(
          child: AnimatedSwitcher(
            duration: AppMotion.normal,
            child: operation == null
                ? const SizedBox.shrink()
                : _Blocker(operation: operation),
          ),
        ),
      ],
    );
  }
}

class _Blocker extends StatelessWidget {
  const _Blocker({required this.operation});

  final ActiveOperation operation;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ModalBarrier(
          dismissible: false,
          color: Colors.black.withValues(alpha: 0.35),
        ),
        Center(child: _ProgressCard(operation: operation)),
      ],
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.operation});

  final ActiveOperation operation;

  String get _title => switch (operation.kind) {
    OperationKind.locking => 'Locking “${operation.itemName}”',
    OperationKind.unlocking => 'Unlocking “${operation.itemName}”',
    OperationKind.opening => 'Opening “${operation.itemName}” as a drive',
  };

  String _phase(OperationPhase? phase) => switch (phase) {
    null || OperationPhase.preparing =>
      operation.kind == OperationKind.locking
          ? 'Getting ready…'
          : 'Checking the password…',
    OperationPhase.encrypting => 'Encrypting files…',
    OperationPhase.verifying => 'Verifying the vault…',
    OperationPhase.decrypting => 'Decrypting files…',
    OperationPhase.finishing => 'Finishing up…',
  };

  @override
  Widget build(BuildContext context) {
    final progress = operation.progress;
    final fraction = progress?.fraction;
    final showCounts = progress != null && progress.totalBytes > 0;
    final canCancel =
        operation.cancel != null && progress?.phase != OperationPhase.finishing;

    return Material(
      type: MaterialType.transparency,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Card(
          elevation: 12,
          shadowColor: Colors.black26,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    IconTile(
                      icon: operation.kind == OperationKind.locking
                          ? Icons.lock_rounded
                          : Icons.lock_open_rounded,
                      size: 44,
                    ),
                    const SizedBox(width: AppSpacing.lg),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _title,
                            style: context.text.titleMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          AnimatedSwitcher(
                            duration: AppMotion.fast,
                            child: Text(
                              _phase(progress?.phase),
                              key: ValueKey(progress?.phase),
                              style: context.text.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (fraction != null)
                      Text(
                        '${(fraction * 100).floor()}%',
                        style: context.text.titleMedium?.copyWith(
                          color: context.colors.primary,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xl),
                TweenAnimationBuilder<double>(
                  tween: Tween(end: fraction ?? 0),
                  duration: AppMotion.normal,
                  builder: (context, value, _) => LinearProgressIndicator(
                    value: fraction == null ? null : value,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        showCounts
                            ? '${Format.bytes(progress.processedBytes)} of '
                                  '${Format.bytes(progress.totalBytes)} · '
                                  '${progress.processedFiles} of '
                                  '${Format.count(progress.totalFiles, 'file')}'
                            : 'Please keep the app open.',
                        style: context.text.bodySmall,
                      ),
                    ),
                    if (canCancel)
                      TextButton(
                        onPressed: operation.cancel,
                        child: const Text('Cancel'),
                      ),
                  ],
                ),
                if (progress?.currentItem case final current?)
                  Text(
                    Format.middleEllipsis(current, 60),
                    style: context.text.bodySmall?.copyWith(
                      color: context.palette.mutedText.withValues(alpha: 0.8),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
