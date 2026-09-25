import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../app/error_text.dart';
import '../../../../core/theme/app_palette.dart';
import '../../../../core/theme/app_tokens.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/app_dialog.dart';
import '../../../../core/widgets/buttons.dart';
import '../../../../core/widgets/feedback.dart';
import '../../../../core/widgets/password_field.dart';
import '../../../../engine/crypto/recovery_key.dart';
import '../../../../engine/engine_exception.dart';
import '../../../../engine/vault/drive_vault.dart';
import '../../../../engine/vault/vault_keys.dart';
import '../../../auth/application/session_controller.dart';
import '../../application/protection_controller.dart';
import '../../domain/protected_item.dart';

/// Asks for the password (or recovery key) of a vault and unlocks it (a
/// drive vault opens as a drive).
///
/// Pass the [item] when the vault is in the list; without it, the vault is
/// added to the list after unlocking. With [decrypt], a drive item is
/// turned back into a normal folder instead. Returns `null` if cancelled.
Future<UnlockOutcome?> showUnlockDialog(
  BuildContext context, {
  required String vaultPath,
  ProtectedItem? item,
  bool decrypt = false,
}) => showDialog<UnlockOutcome>(
  context: context,
  barrierDismissible: false,
  builder: (_) =>
      _UnlockDialog(vaultPath: vaultPath, item: item, decrypt: decrypt),
);

class _UnlockDialog extends ConsumerStatefulWidget {
  const _UnlockDialog({
    required this.vaultPath,
    this.item,
    this.decrypt = false,
  });

  final String vaultPath;
  final ProtectedItem? item;
  final bool decrypt;

  @override
  ConsumerState<_UnlockDialog> createState() => _UnlockDialogState();
}

class _UnlockDialogState extends ConsumerState<_UnlockDialog> {
  final _secret = TextEditingController();
  final _focus = FocusNode();
  bool _useRecoveryKey = false;
  bool _busy = false;
  String? _fieldError;
  String? _error;

  ProtectedItem? get _item => widget.item;

  bool get _isDrive =>
      _item?.isDrive ?? DriveVault.isDrivePath(widget.vaultPath);

  String get _name =>
      _item?.name ??
      p.basenameWithoutExtension(DriveVault.folderOf(widget.vaultPath));

  String get _action => widget.decrypt
      ? 'Decrypt'
      : _isDrive
      ? 'Open'
      : 'Unlock';

  @override
  void dispose() {
    _secret.dispose();
    _focus.dispose();
    super.dispose();
  }

  String get _passwordLabel => switch (_item?.passwordMode) {
    PasswordMode.master => 'Master password',
    PasswordMode.custom => 'Password for this item',
    null => 'Password',
  };

  String? get _hint {
    final item = _item;
    if (item == null) return null;
    return item.passwordMode == PasswordMode.custom
        ? item.passwordHint
        : ref.read(sessionControllerProvider).keystore?.hint;
  }

  Future<void> _submit() async {
    if (_busy || _secret.text.trim().isEmpty) return;
    final VaultCredential credential;
    if (_useRecoveryKey) {
      final key = RecoveryKey.tryParse(_secret.text);
      if (key == null) {
        setState(() => _fieldError = 'That doesn\'t look like a recovery key.');
        return;
      }
      credential = RecoveryCredential(key);
    } else {
      credential = PasswordCredential(_secret.text);
    }

    setState(() {
      _busy = true;
      _fieldError = null;
      _error = null;
    });
    final controller = ref.read(protectionControllerProvider.notifier);
    try {
      final item = _item;
      final outcome = item == null
          ? await controller.unlockUnknownVault(widget.vaultPath, credential)
          : widget.decrypt
          ? await controller.decryptDrive(item, credential: credential)
          : await controller.unlock(item, credential: credential);
      if (mounted) Navigator.of(context).pop(outcome);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (isWrongPassword(error)) {
          _fieldError = _useRecoveryKey
              ? 'That recovery key doesn\'t open this item.'
              : 'That password is not correct.';
        } else if (error is EngineException &&
            error.code == EngineErrorCode.cancelled) {
          _error = null;
        } else {
          _error = errorText(error);
        }
      });
      _focus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final hint = _hint;
    // Escape, or the close button of Explorer's small window, can't close it
    // halfway through unlocking.
    return PopScope(canPop: !_busy, child: _dialog(context, hint));
  }

  Widget _dialog(BuildContext context, String? hint) {
    return AppDialog(
      icon: widget.decrypt
          ? Icons.no_encryption_rounded
          : _isDrive
          ? Icons.storage_rounded
          : Icons.lock_open_rounded,
      title: widget.decrypt
          ? 'Decrypt “$_name” to a folder'
          : '$_action “$_name”',
      subtitle: Format.middleEllipsis(widget.vaultPath, 70),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_item?.needsPassword ?? false) ...[
            const InfoBanner(
              tone: Tone.warning,
              message:
                  'This item still uses your previous master password. Enter '
                  'that password, or use your recovery key.',
            ),
            const SizedBox(height: AppSpacing.lg),
          ],
          if (_useRecoveryKey)
            TextField(
              controller: _secret,
              focusNode: _focus,
              autofocus: true,
              enabled: !_busy,
              style: context.text.bodyLarge?.copyWith(
                fontFamily: 'Consolas',
                fontFamilyFallback: const ['Cascadia Mono', 'monospace'],
                letterSpacing: 1,
              ),
              decoration: InputDecoration(
                labelText: 'Recovery key',
                hintText: 'XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX',
                errorText: _fieldError,
                prefixIcon: const Icon(Icons.vpn_key_outlined, size: 20),
              ),
              onSubmitted: (_) => _submit(),
            )
          else
            PasswordField(
              controller: _secret,
              focusNode: _focus,
              label: _passwordLabel,
              autofocus: true,
              enabled: !_busy,
              errorText: _fieldError,
              onSubmitted: (_) => _submit(),
            ),
          if (hint != null && !_useRecoveryKey) ...[
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Icon(
                  Icons.lightbulb_outline_rounded,
                  size: 16,
                  color: context.palette.mutedText,
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text('Hint: $hint', style: context.text.bodySmall),
                ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _useRecoveryKey = !_useRecoveryKey;
                      _secret.clear();
                      _fieldError = null;
                      _focus.requestFocus();
                    }),
              icon: Icon(
                _useRecoveryKey ? Icons.password_rounded : Icons.key_rounded,
                size: 18,
              ),
              label: Text(
                _useRecoveryKey
                    ? 'Use the password instead'
                    : 'Use the recovery key instead',
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.sm),
            InfoBanner(tone: Tone.danger, message: _error!),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        LoadingButton(
          label: _action,
          icon: widget.decrypt
              ? Icons.no_encryption_rounded
              : _isDrive
              ? Icons.storage_rounded
              : Icons.lock_open_rounded,
          busy: _busy,
          onPressed: _submit,
        ),
      ],
    );
  }
}
