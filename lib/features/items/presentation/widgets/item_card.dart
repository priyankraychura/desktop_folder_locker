import 'package:flutter/material.dart';

import '../../../../core/theme/app_palette.dart';
import '../../../../core/theme/app_tokens.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/icon_tile.dart';
import '../../../../core/widgets/status_badge.dart';
import '../../domain/protected_item.dart';

/// Callbacks for the actions on one item.
class ItemCardActions {
  const ItemCardActions({
    required this.onUnlock,
    required this.onLock,
    required this.onReveal,
    required this.onCopyLocation,
    required this.onRemove,
    this.onDecrypt,
  });

  final VoidCallback onUnlock;
  final VoidCallback onLock;
  final VoidCallback onReveal;
  final VoidCallback onCopyLocation;
  final VoidCallback onRemove;

  /// Turns a drive item back into a normal folder.
  final VoidCallback? onDecrypt;
}

/// How an item looks, derived from its state.
enum _Look {
  locked,
  blocked,
  readOnly,
  hidden,
  unlocked,

  /// A drive item that is open as a drive.
  open,
  missing;

  bool get isProtected => this != unlocked && this != open && this != missing;
}

/// One row in the items list.
class ItemCard extends StatefulWidget {
  const ItemCard({
    required this.item,
    required this.existsOnDisk,
    required this.actions,
    super.key,
    this.enabled = true,
  });

  final ProtectedItem item;
  final bool existsOnDisk;
  final ItemCardActions actions;

  /// `false` while another operation runs.
  final bool enabled;

  @override
  State<ItemCard> createState() => _ItemCardState();
}

class _ItemCardState extends State<ItemCard> {
  bool _hovered = false;

  _Look get _look {
    final item = widget.item;
    if (!widget.existsOnDisk) return _Look.missing;
    if (item.isMounted) return _Look.open;
    if (!item.isProtected) return _Look.unlocked;
    return switch (item.method) {
      ProtectionMethod.encrypt || ProtectionMethod.drive => _Look.locked,
      ProtectionMethod.blockAccess => _Look.blocked,
      ProtectionMethod.readOnly => _Look.readOnly,
      ProtectionMethod.none => _Look.hidden,
    };
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final look = _look;
    final tone = switch (look) {
      _Look.locked || _Look.blocked => Tone.primary,
      _Look.readOnly => Tone.info,
      _Look.hidden => Tone.accent,
      _Look.unlocked || _Look.open => Tone.warning,
      _Look.missing => Tone.danger,
    };
    final isFolder = item.kind == ItemKind.folder;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: AppMotion.fast,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        decoration: BoxDecoration(
          color: _hovered
              ? context.colors.surfaceContainerLow
              : context.colors.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: context.palette.border),
        ),
        child: Row(
          children: [
            IconTile(
              icon: switch (look) {
                _Look.missing => Icons.help_outline_rounded,
                _ when item.isDrive => Icons.storage_rounded,
                _ when isFolder => Icons.folder_rounded,
                _ => Icons.insert_drive_file_rounded,
              },
              tone: tone,
              size: 44,
              badge: switch (look) {
                _Look.locked => Icons.lock_rounded,
                _Look.blocked => Icons.block_rounded,
                _Look.readOnly => Icons.edit_off_rounded,
                _Look.hidden => Icons.visibility_off_rounded,
                _Look.unlocked || _Look.open => Icons.lock_open_rounded,
                _Look.missing => null,
              },
            ),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: _Details(item: item, look: look, tone: tone),
            ),
            const SizedBox(width: AppSpacing.md),
            _PrimaryAction(
              look: look,
              method: item.method,
              enabled: widget.enabled,
              actions: widget.actions,
            ),
            const SizedBox(width: AppSpacing.xs),
            _MoreMenu(
              enabled: widget.enabled,
              canReveal: look != _Look.missing,
              // A drive keeps its vault until it's decrypted to a folder.
              canRemove:
                  look == _Look.missing ||
                  (look == _Look.unlocked && !item.hasVault),
              canDecrypt:
                  item.isDrive && item.hasVault && look != _Look.missing,
              actions: widget.actions,
            ),
          ],
        ),
      ),
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({required this.item, required this.look, required this.tone});

  final ProtectedItem item;
  final _Look look;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    final state = item.isMounted
        ? 'Opened'
        : item.isProtected
        ? 'Protected'
        : 'Unlocked';
    final meta = [
      if (item.sizeBytes != null) Format.bytes(item.sizeBytes),
      if (item.kind == ItemKind.folder && item.fileCount != null)
        Format.count(item.fileCount!, 'file'),
      '$state ${Format.relative(item.updatedAt)}',
    ].join('  ·  ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              item.name,
              style: context.text.titleSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            StatusBadge(
              tone: tone,
              label: switch (look) {
                _Look.locked => 'Locked',
                _Look.blocked => 'Blocked',
                _Look.readOnly => 'Read-only',
                _Look.hidden => 'Hidden',
                _Look.unlocked => 'Unlocked',
                _Look.open => 'Open as ${_driveName(item.mountPoint)}',
                _Look.missing => 'Not found',
              },
            ),
            if (look.isProtected && look != _Look.hidden && item.hide)
              const StatusBadge(tone: Tone.accent, label: 'Hidden'),
            if (item.isDrive)
              const StatusBadge(icon: Icons.storage_rounded, label: 'Drive'),
            // What "Lock" will do again, for the quick methods.
            if (look == _Look.unlocked && !item.method.encrypts)
              StatusBadge(
                label: switch (item.method) {
                  ProtectionMethod.blockAccess => 'Block access',
                  ProtectionMethod.readOnly => 'Read-only',
                  _ => 'Hide only',
                },
              ),
            if (item.method.encrypts &&
                item.passwordMode == PasswordMode.custom)
              const StatusBadge(icon: Icons.key_rounded, label: 'Own password'),
            if (item.needsPassword && look == _Look.locked)
              const StatusBadge(
                tone: Tone.warning,
                icon: Icons.history_rounded,
                label: 'Old password',
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.xxs),
        Tooltip(
          message: item.currentPath,
          child: Text(
            Format.middleEllipsis(item.currentPath, 80),
            style: context.text.bodySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: AppSpacing.xxs),
        Text(
          meta,
          style: context.text.bodySmall?.copyWith(
            color: context.palette.mutedText.withValues(alpha: 0.8),
          ),
        ),
      ],
    );
  }
}

/// `V:` for `V:\`.
String _driveName(String? mountPoint) {
  final point = mountPoint ?? '';
  return point.endsWith('\\') ? point.substring(0, point.length - 1) : point;
}

class _PrimaryAction extends StatelessWidget {
  const _PrimaryAction({
    required this.look,
    required this.method,
    required this.enabled,
    required this.actions,
  });

  final _Look look;
  final ProtectionMethod method;
  final bool enabled;
  final ItemCardActions actions;

  @override
  Widget build(BuildContext context) {
    final hideOnly = method == ProtectionMethod.none;
    final drive = method == ProtectionMethod.drive;
    return switch (look) {
      _Look.locked ||
      _Look.blocked ||
      _Look.readOnly ||
      _Look.hidden => FilledButton.tonalIcon(
        onPressed: enabled ? actions.onUnlock : null,
        icon: Icon(
          hideOnly
              ? Icons.visibility_rounded
              : drive
              ? Icons.storage_rounded
              : Icons.lock_open_rounded,
          size: 18,
        ),
        label: Text(
          hideOnly
              ? 'Show'
              : drive
              ? 'Open'
              : 'Unlock',
        ),
      ),
      _Look.unlocked || _Look.open => FilledButton.icon(
        onPressed: enabled ? actions.onLock : null,
        icon: Icon(switch (method) {
          ProtectionMethod.encrypt ||
          ProtectionMethod.drive => Icons.lock_rounded,
          ProtectionMethod.blockAccess => Icons.block_rounded,
          ProtectionMethod.readOnly => Icons.edit_off_rounded,
          ProtectionMethod.none => Icons.visibility_off_rounded,
        }, size: 18),
        label: Text(hideOnly ? 'Hide' : 'Lock'),
      ),
      _Look.missing => OutlinedButton.icon(
        onPressed: enabled ? actions.onRemove : null,
        icon: const Icon(Icons.playlist_remove_rounded, size: 18),
        label: const Text('Remove'),
      ),
    };
  }
}

class _MoreMenu extends StatelessWidget {
  const _MoreMenu({
    required this.enabled,
    required this.canReveal,
    required this.canRemove,
    required this.canDecrypt,
    required this.actions,
  });

  final bool enabled;
  final bool canReveal;
  final bool canRemove;
  final bool canDecrypt;
  final ItemCardActions actions;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      alignmentOffset: const Offset(-160, 4),
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.folder_open_rounded, size: 18),
          onPressed: canReveal ? actions.onReveal : null,
          child: const Text('Show in Explorer'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.copy_rounded, size: 18),
          onPressed: actions.onCopyLocation,
          child: const Text('Copy location'),
        ),
        if (canDecrypt)
          MenuItemButton(
            leadingIcon: const Icon(Icons.no_encryption_rounded, size: 18),
            onPressed: enabled ? actions.onDecrypt : null,
            child: const Text('Decrypt to a folder…'),
          ),
        const Divider(),
        MenuItemButton(
          leadingIcon: const Icon(Icons.playlist_remove_rounded, size: 18),
          onPressed: canRemove && enabled ? actions.onRemove : null,
          child: const Text('Remove from list'),
        ),
      ],
      builder: (context, controller, _) => IconButton(
        tooltip: 'More',
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.more_horiz_rounded),
      ),
    );
  }
}
