import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../../core/constants/app_info.dart';
import '../../../../core/theme/app_palette.dart';
import '../../../../core/theme/app_tokens.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/app_dialog.dart';
import '../../../../core/widgets/cards.dart';
import '../../../../core/widgets/feedback.dart';
import '../../../../core/widgets/icon_tile.dart';
import '../../../../core/widgets/new_password_fields.dart';
import '../../domain/protected_item.dart';

/// What the user chose in the protect dialog.
class ProtectChoice {
  const ProtectChoice({
    required this.encrypt,
    required this.hide,
    required this.passwordMode,
    this.customPassword,
    this.passwordHint,
  });

  final bool encrypt;
  final bool hide;
  final PasswordMode passwordMode;
  final String? customPassword;
  final String? passwordHint;
}

/// Asks how to protect a new item.
Future<ProtectChoice?> showProtectDialog(
  BuildContext context, {
  required String path,
  required ItemKind kind,
}) => showDialog<ProtectChoice>(
  context: context,
  builder: (_) => _ProtectDialog(path: path, kind: kind),
);

/// Asks for the password of a custom-password item before locking it again.
Future<ProtectChoice?> showRelockDialog(
  BuildContext context, {
  required ProtectedItem item,
}) => showDialog<ProtectChoice>(
  context: context,
  builder: (_) =>
      _ProtectDialog(path: item.itemPath, kind: item.kind, relock: item),
);

class _ProtectDialog extends StatefulWidget {
  const _ProtectDialog({required this.path, required this.kind, this.relock});

  final String path;
  final ItemKind kind;

  /// Set when locking an existing custom-password item again.
  final ProtectedItem? relock;

  @override
  State<_ProtectDialog> createState() => _ProtectDialogState();
}

class _ProtectDialogState extends State<_ProtectDialog> {
  late bool _encrypt = widget.relock?.encrypt ?? true;
  late bool _hide = widget.relock?.hide ?? false;
  late PasswordMode _mode = widget.relock?.passwordMode ?? PasswordMode.master;
  final _form = NewPasswordController();

  bool get _isRelock => widget.relock != null;
  String get _name => p.basename(widget.path);

  @override
  void initState() {
    super.initState();
    _form.hint.text = widget.relock?.passwordHint ?? '';
  }

  @override
  void dispose() {
    _form.dispose();
    super.dispose();
  }

  String get _actionLabel => switch ((_encrypt, _hide)) {
    (true, true) => 'Lock and hide',
    (true, false) => 'Lock',
    (false, true) => 'Hide',
    (false, false) => 'Lock',
  };

  String get _outcome {
    final vaultName = '$_name${AppInfo.vaultExtension}';
    if (_encrypt && _hide) {
      return '“$_name” becomes an encrypted vault ($vaultName) and is hidden '
          'from Explorer. Unlock it from this app.';
    }
    if (_encrypt) {
      return '“$_name” becomes an encrypted vault ($vaultName) in the same '
          'place. Double-click it in Explorer any time to unlock it.';
    }
    return '“$_name” disappears from Explorer until you show it again here. '
        'Its files are not encrypted.';
  }

  void _submit() {
    if (!_encrypt && !_hide) return;
    final needsPassword = _encrypt && _mode == PasswordMode.custom;
    if (needsPassword && !_form.validate()) return;
    Navigator.of(context).pop(
      ProtectChoice(
        encrypt: _encrypt,
        hide: _hide,
        passwordMode: _mode,
        customPassword: needsPassword ? _form.password.text : null,
        passwordHint: needsPassword ? _form.hintText : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isFolder = widget.kind == ItemKind.folder;
    return AppDialog(
      icon: Icons.lock_rounded,
      title: _isRelock ? 'Lock “$_name” again' : 'Protect “$_name”',
      subtitle: _isRelock
          ? 'Enter a password for this item.'
          : 'Choose how to protect this ${isFolder ? 'folder' : 'file'}.',
      width: 540,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ItemSummary(path: widget.path, isFolder: isFolder),
          if (!_isRelock) ...[
            const SizedBox(height: AppSpacing.xl),
            const _Label('Protection'),
            OptionCard(
              icon: Icons.enhanced_encryption_rounded,
              title: 'Encrypt  ·  recommended',
              description:
                  'Turns it into a password-protected vault. Safe even if '
                  'someone copies it or takes the disk.',
              selected: _encrypt,
              onChanged: (value) => setState(() => _encrypt = value),
            ),
            const SizedBox(height: AppSpacing.sm),
            OptionCard(
              icon: Icons.visibility_off_rounded,
              tone: Tone.accent,
              title: 'Hide',
              description:
                  'Hides it from Explorer. Instant, but anyone who knows how '
                  'to show hidden files can still find it.',
              selected: _hide,
              onChanged: (value) => setState(() => _hide = value),
            ),
          ],
          AnimatedSize(
            duration: AppMotion.normal,
            curve: AppMotion.curve,
            alignment: Alignment.topCenter,
            child: _encrypt
                ? _passwordSection(context)
                : const SizedBox(width: double.infinity),
          ),
          const SizedBox(height: AppSpacing.xl),
          if (_encrypt || _hide)
            InfoBanner(message: _outcome, icon: Icons.info_outline_rounded)
          else
            const InfoBanner(
              tone: Tone.warning,
              message: 'Choose at least one way to protect this item.',
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _encrypt || _hide ? _submit : null,
          icon: Icon(
            _encrypt ? Icons.lock_rounded : Icons.visibility_off_rounded,
            size: 18,
          ),
          label: Text(_actionLabel),
        ),
      ],
    );
  }

  Widget _passwordSection(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!_isRelock) ...[
            const _Label('Password'),
            SegmentedButton<PasswordMode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: PasswordMode.master,
                  icon: Icon(Icons.key_rounded, size: 18),
                  label: Text('Master password'),
                ),
                ButtonSegment(
                  value: PasswordMode.custom,
                  icon: Icon(Icons.password_rounded, size: 18),
                  label: Text('Its own password'),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (value) =>
                  setState(() => _mode = value.first),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              _mode == PasswordMode.master
                  ? 'Unlocks with your master password, or right away while '
                        'the app is unlocked.'
                  : 'Only this password (or your recovery key) opens it. '
                        'Useful to share one item with someone else.',
              style: context.text.bodySmall,
            ),
          ],
          if (_mode == PasswordMode.custom) ...[
            const SizedBox(height: AppSpacing.lg),
            NewPasswordFields(
              controller: _form,
              passwordLabel: 'Password for this item',
              autofocus: _isRelock,
              onSubmitted: _submit,
            ),
          ],
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
    child: Text(text, style: context.text.labelLarge),
  );
}

class _ItemSummary extends StatelessWidget {
  const _ItemSummary({required this.path, required this.isFolder});

  final String path;
  final bool isFolder;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: context.palette.border),
      ),
      child: Row(
        children: [
          IconTile(
            icon: isFolder
                ? Icons.folder_rounded
                : Icons.insert_drive_file_rounded,
            tone: Tone.neutral,
            size: 36,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.basename(path),
                  style: context.text.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  Format.middleEllipsis(p.dirname(path), 64),
                  style: context.text.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
