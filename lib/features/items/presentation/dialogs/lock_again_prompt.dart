import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_info.dart';
import '../../../../core/theme/app_palette.dart';
import '../../../../core/theme/app_tokens.dart';
import '../../../../core/widgets/app_dialog.dart';
import '../../../../core/widgets/buttons.dart';
import '../../../../core/widgets/password_field.dart';
import '../../../auth/application/session_controller.dart';
import '../../application/protection_controller.dart';
import '../../domain/protected_item.dart';

/// Asks whether to lock [item] again, now that its last Explorer window
/// [closed]. Returns `true` to lock it.
///
/// With [askMasterPassword] (the app locked itself since the item was
/// unlocked, and locking needs the master password), asks for it too and
/// keeps the key for the item, so it can be locked.
Future<bool> showLockAgainPrompt(
  BuildContext context, {
  required ProtectedItem item,
  required bool closed,
  required bool askMasterPassword,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _LockAgainPrompt(
        item: item,
        closed: closed,
        askMasterPassword: askMasterPassword,
      ),
    ) ??
    false;

class _LockAgainPrompt extends ConsumerStatefulWidget {
  const _LockAgainPrompt({
    required this.item,
    required this.closed,
    required this.askMasterPassword,
  });

  final ProtectedItem item;
  final bool closed;
  final bool askMasterPassword;

  @override
  ConsumerState<_LockAgainPrompt> createState() => _LockAgainPromptState();
}

class _LockAgainPromptState extends ConsumerState<_LockAgainPrompt> {
  final TextEditingController _password = TextEditingController();
  bool _busy = false;
  String? _fieldError;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _lock() async {
    if (!widget.askMasterPassword) {
      Navigator.of(context).pop(true);
      return;
    }
    if (_busy || _password.text.isEmpty) return;
    setState(() {
      _busy = true;
      _fieldError = null;
    });
    final key = await ref
        .read(sessionControllerProvider.notifier)
        .masterKeyFor(_password.text);
    if (!mounted) {
      key?.dispose();
      return;
    }
    if (key == null) {
      setState(() {
        _busy = false;
        _fieldError = 'That password is not correct.';
      });
      return;
    }
    ref
        .read(protectionControllerProvider.notifier)
        .rememberMasterKey(widget.item, key);
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return PopScope(
      canPop: !_busy,
      child: AppDialog(
        icon: Icons.lock_rounded,
        title: 'Lock “${item.name}” again?',
        subtitle: widget.closed
            ? item.isMounted
                  ? 'You closed its drive (${item.driveName}) in Explorer.'
                  : 'You closed it in Explorer.'
            : null,
        content: widget.askMasterPassword
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PasswordField(
                    controller: _password,
                    label: 'Master password',
                    autofocus: true,
                    enabled: !_busy,
                    errorText: _fieldError,
                    onSubmitted: (_) => _lock(),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    '${AppInfo.name} locked itself since you opened it, so '
                    'locking it needs your master password.',
                    style: context.text.bodySmall,
                  ),
                ],
              )
            : null,
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
          LoadingButton(
            label: 'Lock',
            icon: Icons.lock_rounded,
            busy: _busy,
            onPressed: _lock,
          ),
        ],
      ),
    );
  }
}
