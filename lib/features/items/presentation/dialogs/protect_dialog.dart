import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../../app/error_text.dart';
import '../../../../core/constants/app_info.dart';
import '../../../../core/theme/app_palette.dart';
import '../../../../core/theme/app_tokens.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/app_dialog.dart';
import '../../../../core/widgets/cards.dart';
import '../../../../core/widgets/feedback.dart';
import '../../../../core/widgets/icon_tile.dart';
import '../../../../core/widgets/new_password_fields.dart';
import '../../../../platform/access_control.dart';
import '../../domain/protected_item.dart';

/// What the user chose in the protect dialog.
class ProtectChoice {
  const ProtectChoice({
    required this.method,
    required this.hide,
    required this.passwordMode,
    this.customPassword,
    this.passwordHint,
  });

  final ProtectionMethod method;
  final bool hide;
  final PasswordMode passwordMode;
  final String? customPassword;
  final String? passwordHint;
}

/// Asks how to protect a new item. [accessProblem] explains why Block
/// access and Read-only can't be used for it (`null` if they can).
Future<ProtectChoice?> showProtectDialog(
  BuildContext context, {
  required String path,
  required ItemKind kind,
  AccessProblem? accessProblem,
}) => showDialog<ProtectChoice>(
  context: context,
  builder: (_) =>
      _ProtectDialog(path: path, kind: kind, accessProblem: accessProblem),
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
  const _ProtectDialog({
    required this.path,
    required this.kind,
    this.relock,
    this.accessProblem,
  });

  final String path;
  final ItemKind kind;
  final AccessProblem? accessProblem;

  /// Set when locking an existing custom-password item again.
  final ProtectedItem? relock;

  @override
  State<_ProtectDialog> createState() => _ProtectDialogState();
}

class _ProtectDialogState extends State<_ProtectDialog> {
  late ProtectionMethod _method =
      widget.relock?.method ?? ProtectionMethod.encrypt;
  late bool _hide = widget.relock?.hide ?? false;
  late PasswordMode _mode = widget.relock?.passwordMode ?? PasswordMode.master;
  final _form = NewPasswordController();

  bool get _isRelock => widget.relock != null;
  String get _name => p.basename(widget.path);
  bool get _encrypt => _method == ProtectionMethod.encrypt;

  /// "Hide only" means hiding is the whole protection.
  bool get _hidden => _hide || _method == ProtectionMethod.none;

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

  String get _actionLabel => switch (_method) {
    ProtectionMethod.encrypt => _hide ? 'Lock and hide' : 'Lock',
    ProtectionMethod.blockAccess => _hide ? 'Block and hide' : 'Block',
    ProtectionMethod.readOnly => 'Make read-only',
    ProtectionMethod.none => 'Hide',
  };

  IconData get _actionIcon => switch (_method) {
    ProtectionMethod.encrypt => Icons.lock_rounded,
    ProtectionMethod.blockAccess => Icons.block_rounded,
    ProtectionMethod.readOnly => Icons.edit_off_rounded,
    ProtectionMethod.none => Icons.visibility_off_rounded,
  };

  String get _outcome {
    final vaultName = '$_name${AppInfo.vaultExtension}';
    final hidden = _hide ? ' and hidden from Explorer' : '';
    return switch (_method) {
      ProtectionMethod.encrypt when _hide =>
        '“$_name” becomes an encrypted vault ($vaultName) and is hidden '
            'from Explorer. Unlock it from this app.',
      ProtectionMethod.encrypt =>
        '“$_name” becomes an encrypted vault ($vaultName) in the same '
            'place. Double-click it in Explorer any time to unlock it.',
      ProtectionMethod.blockAccess =>
        '“$_name” stays where it is$hidden, but nobody can open it until '
            'you unlock it here. Its files are not encrypted.',
      ProtectionMethod.readOnly =>
        '“$_name” stays where it is$hidden and can be opened, but nothing '
            'in it can be changed or deleted until you unlock it here.',
      ProtectionMethod.none =>
        '“$_name” disappears from Explorer until you show it again here. '
            'Its files are not encrypted.',
    };
  }

  void _submit() {
    final needsPassword = _encrypt && _mode == PasswordMode.custom;
    if (needsPassword && !_form.validate()) return;
    Navigator.of(context).pop(
      ProtectChoice(
        method: _method,
        hide: _hidden,
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
            ..._methodOptions(),
            AnimatedSize(
              duration: AppMotion.normal,
              curve: AppMotion.curve,
              alignment: Alignment.topCenter,
              child: _method == ProtectionMethod.none
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.sm),
                      child: _HideToggle(
                        value: _hide,
                        onChanged: (value) => setState(() => _hide = value),
                      ),
                    ),
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
          InfoBanner(
            message: _outcome,
            icon: Icons.info_outline_rounded,
            tone: _encrypt ? Tone.info : Tone.warning,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: Icon(_actionIcon, size: 18),
          label: Text(_actionLabel),
        ),
      ],
    );
  }

  List<Widget> _methodOptions() {
    final problem = widget.accessProblem;
    Widget tile(
      ProtectionMethod method, {
      required IconData icon,
      required String title,
      required String subtitle,
      Tone tone = Tone.primary,
    }) {
      final enabled = !method.usesAccessRule || problem == null;
      return Expanded(
        child: ChoiceTile(
          icon: icon,
          tone: tone,
          title: title,
          subtitle: enabled ? subtitle : accessProblemShortText(problem),
          selected: _method == method,
          enabled: enabled,
          onSelected: () => setState(() => _method = method),
        ),
      );
    }

    Widget row(List<Widget> tiles) => IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          tiles[0],
          const SizedBox(width: AppSpacing.sm),
          tiles[1],
        ],
      ),
    );

    return [
      row([
        tile(
          ProtectionMethod.encrypt,
          icon: Icons.enhanced_encryption_rounded,
          title: 'Encrypt  ·  recommended',
          subtitle: 'Real encryption. Safe even if it is copied or stolen.',
        ),
        tile(
          ProtectionMethod.blockAccess,
          icon: Icons.block_rounded,
          tone: Tone.danger,
          title: 'Block access',
          subtitle: 'Nobody can open or delete it. Instant, not encrypted.',
        ),
      ]),
      const SizedBox(height: AppSpacing.sm),
      row([
        tile(
          ProtectionMethod.readOnly,
          icon: Icons.edit_off_rounded,
          tone: Tone.info,
          title: 'Read-only',
          subtitle: 'Can be opened, but not changed. Instant, not encrypted.',
        ),
        tile(
          ProtectionMethod.none,
          icon: Icons.visibility_off_rounded,
          tone: Tone.accent,
          title: 'Hide only',
          subtitle: 'Invisible in Explorer, unless hidden files are shown.',
        ),
      ]),
    ];
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

class _HideToggle extends StatelessWidget {
  const _HideToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xs,
          vertical: AppSpacing.xxs,
        ),
        child: Row(
          children: [
            Icon(
              Icons.visibility_off_rounded,
              size: 20,
              color: context.palette.tone(Tone.accent).foreground,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                'Also hide it from Explorer',
                style: context.text.titleSmall,
              ),
            ),
            Switch(value: value, onChanged: onChanged),
          ],
        ),
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
