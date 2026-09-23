import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_palette.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/cards.dart';
import '../../../core/widgets/feedback.dart';
import '../application/items_controller.dart';
import '../application/protection_controller.dart';
import '../domain/protected_item.dart';
import 'item_actions.dart';
import 'widgets/drop_zone.dart';
import 'widgets/item_card.dart';

enum ItemFilter { all, locked, unlocked, hidden }

extension on ItemFilter {
  bool matches(ProtectedItem item) => switch (this) {
    ItemFilter.all => true,
    ItemFilter.locked =>
      item.isProtected && item.method != ProtectionMethod.none,
    ItemFilter.unlocked => !item.isProtected,
    ItemFilter.hidden => item.hide && item.isProtected,
  };
}

/// The main screen: every protected item, with search, filters and drag &
/// drop.
class ItemsPage extends ConsumerStatefulWidget {
  const ItemsPage({super.key});

  @override
  ConsumerState<ItemsPage> createState() => _ItemsPageState();
}

class _ItemsPageState extends ConsumerState<ItemsPage> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  ItemFilter _filter = ItemFilter.all;
  bool _dragging = false;

  ItemActions get _actions => ItemActions(context, ref);

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _onDrop(DropDoneDetails details) async {
    setState(() => _dragging = false);
    for (final file in details.files) {
      if (!mounted) return;
      await _actions.protectPath(file.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final itemsAsync = ref.watch(itemsControllerProvider);
    final busy = ref.watch(protectionControllerProvider) != null;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyO, control: true): () =>
            unawaited(_actions.pickAndProtect(folder: true)),
        const SingleActivator(
          LogicalKeyboardKey.keyO,
          control: true,
          shift: true,
        ): () =>
            unawaited(_actions.pickAndProtect(folder: false)),
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _searchFocus.requestFocus,
      },
      child: Focus(
        autofocus: true,
        child: DropTarget(
          enable: !busy,
          onDragEntered: (_) => setState(() => _dragging = true),
          onDragExited: (_) => setState(() => _dragging = false),
          onDragDone: _onDrop,
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xxl,
                  AppSpacing.xl,
                  AppSpacing.xxl,
                  0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Header(
                      busy: busy,
                      onAddFolder: () => _actions.pickAndProtect(folder: true),
                      onAddFile: () => _actions.pickAndProtect(folder: false),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    Expanded(
                      child: itemsAsync.when(
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (error, _) => EmptyState(
                          icon: Icons.error_outline_rounded,
                          title: 'Your list could not be loaded',
                          message: '$error',
                        ),
                        data: (items) => items.isEmpty
                            ? _EmptyItems(
                                onAddFolder: () =>
                                    _actions.pickAndProtect(folder: true),
                                onAddFile: () =>
                                    _actions.pickAndProtect(folder: false),
                              )
                            : _content(items, busy),
                      ),
                    ),
                  ],
                ),
              ),
              if (_dragging) const Positioned.fill(child: DropOverlay()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(List<ProtectedItem> items, bool busy) {
    final controller = ref.read(itemsControllerProvider.notifier);
    final query = _search.text.trim().toLowerCase();
    final visible = [
      for (final item in items)
        if (_filter.matches(item) &&
            (query.isEmpty ||
                item.name.toLowerCase().contains(query) ||
                item.currentPath.toLowerCase().contains(query)))
          item,
    ];
    final counts = {
      for (final filter in ItemFilter.values)
        filter: items.where(filter.matches).length,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Stats(
          counts: counts,
          selected: _filter,
          onSelect: (filter) => setState(
            () => _filter = _filter == filter ? ItemFilter.all : filter,
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        _Toolbar(
          search: _search,
          searchFocus: _searchFocus,
          filter: _filter,
          onSearch: (_) => setState(() {}),
          onFilter: (filter) => setState(() => _filter = filter),
        ),
        const SizedBox(height: AppSpacing.md),
        Expanded(
          child: visible.isEmpty
              ? const EmptyState(
                  icon: Icons.search_off_rounded,
                  title: 'Nothing matches',
                  message: 'Try another search or filter.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
                  itemCount: visible.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: AppSpacing.sm),
                  itemBuilder: (context, index) {
                    final item = visible[index];
                    return ItemCard(
                      key: ValueKey(item.id),
                      item: item,
                      existsOnDisk: controller.existsOnDisk(item),
                      enabled: !busy,
                      actions: ItemCardActions(
                        onUnlock: () => _actions.unlock(item),
                        onLock: () => _actions.lockAgain(item),
                        onReveal: () => _actions.reveal(item),
                        onCopyLocation: () => _actions.copyLocation(item),
                        onRemove: () => _actions.remove(item),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.busy,
    required this.onAddFolder,
    required this.onAddFile,
  });

  final bool busy;
  final VoidCallback onAddFolder;
  final VoidCallback onAddFile;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Protected items', style: context.text.headlineMedium),
              const SizedBox(height: AppSpacing.xxs),
              Text(
                'Encrypt, block or hide files and folders. Drag them here to start.',
                style: context.text.bodyMedium?.copyWith(
                  color: context.palette.mutedText,
                ),
              ),
            ],
          ),
        ),
        MenuAnchor(
          alignmentOffset: const Offset(0, 6),
          menuChildren: [
            MenuItemButton(
              leadingIcon: const Icon(
                Icons.create_new_folder_rounded,
                size: 18,
              ),
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyO,
                control: true,
              ),
              onPressed: onAddFolder,
              child: const Text('Lock a folder…'),
            ),
            MenuItemButton(
              leadingIcon: const Icon(Icons.note_add_rounded, size: 18),
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyO,
                control: true,
                shift: true,
              ),
              onPressed: onAddFile,
              child: const Text('Lock a file…'),
            ),
          ],
          builder: (context, controller, _) => FilledButton.icon(
            onPressed: busy
                ? null
                : () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
            icon: const Icon(Icons.add_rounded, size: 20),
            label: const Text('Add item'),
          ),
        ),
      ],
    );
  }
}

class _Stats extends StatelessWidget {
  const _Stats({
    required this.counts,
    required this.selected,
    required this.onSelect,
  });

  final Map<ItemFilter, int> counts;
  final ItemFilter selected;
  final ValueChanged<ItemFilter> onSelect;

  @override
  Widget build(BuildContext context) {
    Widget card(ItemFilter filter, IconData icon, String label, Tone tone) =>
        Expanded(
          child: StatCard(
            icon: icon,
            label: label,
            value: '${counts[filter] ?? 0}',
            tone: tone,
            selected: selected == filter,
            onTap: () => onSelect(filter),
          ),
        );

    return Row(
      children: [
        card(ItemFilter.locked, Icons.lock_rounded, 'Locked', Tone.primary),
        const SizedBox(width: AppSpacing.md),
        card(
          ItemFilter.unlocked,
          Icons.lock_open_rounded,
          'Unlocked',
          Tone.warning,
        ),
        const SizedBox(width: AppSpacing.md),
        card(
          ItemFilter.hidden,
          Icons.visibility_off_rounded,
          'Hidden',
          Tone.accent,
        ),
      ],
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.search,
    required this.searchFocus,
    required this.filter,
    required this.onSearch,
    required this.onFilter,
  });

  final TextEditingController search;
  final FocusNode searchFocus;
  final ItemFilter filter;
  final ValueChanged<String> onSearch;
  final ValueChanged<ItemFilter> onFilter;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 320,
          child: TextField(
            controller: search,
            focusNode: searchFocus,
            onChanged: onSearch,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search by name or location  (Ctrl+F)',
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              suffixIcon: search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear',
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: () {
                        search.clear();
                        onSearch('');
                      },
                    ),
            ),
          ),
        ),
        const Spacer(),
        SegmentedButton<ItemFilter>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: ItemFilter.all, label: Text('All')),
            ButtonSegment(value: ItemFilter.locked, label: Text('Locked')),
            ButtonSegment(value: ItemFilter.unlocked, label: Text('Unlocked')),
            ButtonSegment(value: ItemFilter.hidden, label: Text('Hidden')),
          ],
          selected: {filter},
          onSelectionChanged: (value) => onFilter(value.first),
        ),
      ],
    );
  }
}

class _EmptyItems extends StatelessWidget {
  const _EmptyItems({required this.onAddFolder, required this.onAddFile});

  final VoidCallback onAddFolder;
  final VoidCallback onAddFile;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
      child: DashedBorder(
        child: EmptyState(
          icon: Icons.shield_moon_rounded,
          title: 'Nothing protected yet',
          message:
              'Drag a folder or file here, or add one below. You can also '
              'right-click any folder in Explorer and choose “Lock with '
              'Folder Locker”.',
          actions: [
            FilledButton.icon(
              onPressed: onAddFolder,
              icon: const Icon(Icons.create_new_folder_rounded, size: 18),
              label: const Text('Lock a folder'),
            ),
            OutlinedButton.icon(
              onPressed: onAddFile,
              icon: const Icon(Icons.note_add_rounded, size: 18),
              label: const Text('Lock a file'),
            ),
          ],
        ),
      ),
    );
  }
}
