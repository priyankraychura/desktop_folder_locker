import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../app/error_text.dart';
import '../../../core/theme/app_palette.dart';
import '../../../core/widgets/app_dialog.dart';
import '../../../core/widgets/feedback.dart';
import '../../../engine/engine_exception.dart';
import '../../../engine/vault/fs_utils.dart';
import '../../../platform/shell_actions.dart';
import '../../auth/application/session_controller.dart';
import '../../settings/application/settings_controller.dart';
import '../application/items_controller.dart';
import '../application/protection_controller.dart';
import '../domain/protected_item.dart';
import 'dialogs/protect_dialog.dart';
import 'dialogs/unlock_dialog.dart';

/// The user-facing flows for items (dialogs, confirmations and toasts),
/// shared by the items page and requests coming from Explorer.
class ItemActions {
  const ItemActions(this._context, this._ref);

  final BuildContext _context;
  final WidgetRef _ref;

  ProtectionController get _controller =>
      _ref.read(protectionControllerProvider.notifier);

  /// Lets the user pick a folder or file, then protects it.
  Future<void> pickAndProtect({required bool folder}) async {
    final String? path;
    if (folder) {
      path = await getDirectoryPath(confirmButtonText: 'Choose folder');
    } else {
      path = (await openFile(confirmButtonText: 'Choose file'))?.path;
    }
    if (path != null) await protectPath(path);
  }

  /// Protects [path] after asking how (encrypt / hide, which password).
  Future<void> protectPath(String path) async {
    if (!_ref.read(sessionControllerProvider).isUnlocked) {
      showToast('Unlock the app first.', tone: Tone.warning);
      return;
    }
    if (_controller.checkPath(path) case final problem?) {
      showToast(pathProblemText(problem), tone: Tone.warning);
      return;
    }
    if (!_context.mounted) return;
    final choice = await showProtectDialog(
      _context,
      path: path,
      kind: FsUtils.isDirectory(path) ? ItemKind.folder : ItemKind.file,
    );
    if (choice == null) return;
    await _run(() async {
      final item = await _controller.protectNew(
        ProtectRequest(
          path: path,
          encrypt: choice.encrypt,
          hide: choice.hide,
          passwordMode: choice.passwordMode,
          customPassword: choice.customPassword,
          passwordHint: choice.passwordHint,
        ),
      );
      _toastProtected(item);
    });
  }

  /// Unlocks an item, asking for a password only when needed.
  Future<void> unlock(ProtectedItem item, {bool? openAfter}) async {
    final open =
        openAfter ?? _ref.read(settingsControllerProvider).openAfterUnlock;
    UnlockOutcome? outcome;

    final canSkipPassword =
        !item.encrypt || _controller.sessionCredential(item) != null;
    if (canSkipPassword) {
      try {
        outcome = await _controller.unlock(item);
      } on Object catch (error) {
        if (!isWrongPassword(error)) {
          _toastError(error);
          return;
        }
        // The remembered key no longer matches: ask for the password.
      }
    }

    if (outcome == null) {
      final vaultPath = item.vaultPath;
      if (vaultPath == null || !_context.mounted) return;
      outcome = await showUnlockDialog(
        _context,
        vaultPath: vaultPath,
        item: item,
      );
    }
    if (outcome != null) _afterUnlock(outcome, open: open);
  }

  /// Applies the item's protection again.
  Future<void> lockAgain(ProtectedItem item) async {
    String? customPassword;
    String? hint;
    switch (_controller.lockRequirement(item)) {
      case LockRequirement.none:
        break;
      case LockRequirement.appUnlock:
        showToast(
          'Unlock the app with your master password to lock this item again.',
          tone: Tone.warning,
        );
        return;
      case LockRequirement.customPassword:
        if (!_context.mounted) return;
        final choice = await showRelockDialog(_context, item: item);
        if (choice == null) return;
        customPassword = choice.customPassword;
        hint = choice.passwordHint ?? '';
    }
    await _run(() async {
      final locked = await _controller.lockAgain(
        item,
        customPassword: customPassword,
        passwordHint: hint,
      );
      _toastProtected(locked);
    });
  }

  /// Removes an unlocked (or missing) item from the list.
  Future<void> remove(ProtectedItem item) async {
    final confirmed = await showConfirmDialog(
      _context,
      title: 'Remove “${item.name}” from the list?',
      message: item.isProtected
          ? 'Its files can no longer be found, so nothing will be changed on '
                'disk.'
          : 'The item stays where it is, unlocked. You can protect it again '
                'at any time.',
      confirmLabel: 'Remove',
      icon: Icons.playlist_remove_rounded,
      tone: Tone.danger,
      destructive: true,
    );
    if (!confirmed) return;
    await _run(() async {
      await _controller.remove(item);
      showToast('“${item.name}” was removed from the list.');
    });
  }

  /// A vault was opened from Explorer.
  Future<void> openVault(String vaultPath) async {
    if (!FsUtils.exists(vaultPath)) {
      showToast('That vault no longer exists.', tone: Tone.warning);
      return;
    }
    final item = _ref.read(itemsControllerProvider.notifier).byPath(vaultPath);
    if (item != null && item.isEncryptedNow) {
      // Explorer requests always ask for the password.
      if (!_context.mounted) return;
      final outcome = await showUnlockDialog(
        _context,
        vaultPath: vaultPath,
        item: item,
      );
      if (outcome != null) _afterUnlock(outcome, open: true);
      return;
    }
    if (!_context.mounted) return;
    final outcome = await showUnlockDialog(_context, vaultPath: vaultPath);
    if (outcome != null) _afterUnlock(outcome, open: true);
  }

  Future<void> reveal(ProtectedItem item) async {
    if (!await ShellActions.reveal(item.currentPath)) {
      showToast('Explorer could not be opened.', tone: Tone.warning);
    }
  }

  Future<void> copyLocation(ProtectedItem item) async {
    await Clipboard.setData(ClipboardData(text: item.currentPath));
    showToast('Location copied.');
  }

  // -------------------------------------------------------------------------

  void _afterUnlock(UnlockOutcome outcome, {required bool open}) {
    final item = outcome.item;
    if (open) unawaited(ShellActions.reveal(item.itemPath));
    final renamed = outcome.renamed
        ? ' Something already existed at the original location, so it was '
              'restored as “${p.basename(item.itemPath)}”.'
        : '';
    showToast(
      '“${item.name}” is unlocked.$renamed',
      tone: Tone.success,
      icon: Icons.lock_open_rounded,
      actionLabel: open ? null : 'Open',
      onAction: open
          ? null
          : () => unawaited(ShellActions.reveal(item.itemPath)),
    );
  }

  void _toastProtected(ProtectedItem item) {
    final message = switch ((item.encrypt, item.hide)) {
      (true, true) => '“${item.name}” is encrypted and hidden.',
      (true, false) => '“${item.name}” is locked.',
      _ => '“${item.name}” is hidden.',
    };
    showToast(
      message,
      tone: Tone.success,
      icon: item.encrypt ? Icons.lock_rounded : Icons.visibility_off_rounded,
      actionLabel: item.hide ? null : 'Show in Explorer',
      onAction: item.hide
          ? null
          : () => unawaited(ShellActions.reveal(item.currentPath)),
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (error) {
      _toastError(error);
    }
  }

  void _toastError(Object error) {
    final cancelled =
        error is EngineException && error.code == EngineErrorCode.cancelled;
    showToast(errorText(error), tone: cancelled ? Tone.neutral : Tone.danger);
  }
}
