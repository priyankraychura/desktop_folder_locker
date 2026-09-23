import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/error_text.dart';
import '../../../core/theme/app_palette.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_dialog.dart';
import '../../../core/widgets/buttons.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/recovery_key_box.dart';
import '../application/auth_service.dart';
import '../application/recovery_key_service.dart';

/// Creates a new recovery key: explains what happens, shows the key once,
/// and switches the vaults over after the user saved it.
Future<void> showNewRecoveryKeyDialog(BuildContext context) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => const _NewRecoveryKeyDialog(),
);

class _NewRecoveryKeyDialog extends ConsumerStatefulWidget {
  const _NewRecoveryKeyDialog();

  @override
  ConsumerState<_NewRecoveryKeyDialog> createState() =>
      _NewRecoveryKeyDialogState();
}

class _NewRecoveryKeyDialogState extends ConsumerState<_NewRecoveryKeyDialog> {
  RecoveryKeyDraft? _draft;
  bool _saved = false;
  bool _busy = false;

  RecoveryKeyService get _service => ref.read(recoveryKeyServiceProvider);

  Future<void> _activate() async {
    final draft = _draft;
    if (draft == null) return;
    setState(() => _busy = true);
    try {
      final stale = await _service.activate(draft);
      if (!mounted) return;
      Navigator.of(context).pop();
      if (stale.isEmpty) {
        showToast(
          'Your new recovery key is active, and every vault opens with it.',
          tone: Tone.success,
        );
      } else {
        showToast(
          'Your new recovery key is active. ${Format.count(stale.length, 'item')} '
          'still open only with the old key until you unlock them (they have '
          'their own password, or their drive is not connected).',
          tone: Tone.warning,
        );
      }
    } on Object catch (error) {
      if (mounted) setState(() => _busy = false);
      showToast(errorText(error), tone: Tone.danger);
    }
  }

  @override
  Widget build(BuildContext context) {
    final draft = _draft;
    if (draft == null) {
      return AppDialog(
        icon: Icons.key_rounded,
        tone: Tone.success,
        title: 'Create a new recovery key?',
        subtitle: 'For example if it was lost, or someone may have seen it.',
        width: 520,
        content: const Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InfoBanner(
              icon: Icons.info_outline_rounded,
              message:
                  'Your current recovery key will no longer reset your master '
                  'password, and your locked items switch to the new key. '
                  'Items with their own password that are locked right now '
                  'switch the next time you unlock them.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => setState(() => _draft = _service.draft()),
            child: const Text('Create new key'),
          ),
        ],
      );
    }

    return AppDialog(
      icon: Icons.key_rounded,
      tone: Tone.success,
      title: 'Your new recovery key',
      subtitle: 'Save it now: it is shown only once.',
      width: 560,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RecoveryKeyBox(recoveryKey: draft.text),
          const SizedBox(height: AppSpacing.md),
          CheckboxListTile(
            value: _saved,
            onChanged: _busy
                ? null
                : (value) => setState(() => _saved = value ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            title: Text(
              'I saved my new recovery key somewhere safe',
              style: context.text.bodyMedium,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        LoadingButton(
          label: 'Use this key',
          icon: Icons.check_rounded,
          busy: _busy,
          onPressed: _saved ? _activate : null,
        ),
      ],
    );
  }
}
