import 'package:flutter/material.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/ui/theme/theme.dart';

import 'transactions_controller.dart';

/// Opens the filter sheet and returns the filter the user settled on, or `null`
/// if they backed out without applying.
Future<TxnFilter?> showFilterSheet(
  BuildContext context, {
  required TxnFilter current,
  required List<CategoryDef> taxonomy,
  required List<Account> accounts,
  required DateTime now,
}) {
  return showModalBottomSheet<TxnFilter>(
    context: context,
    isScrollControlled: true,
    builder: (BuildContext sheetContext) => _FilterSheet(
      initial: current,
      taxonomy: taxonomy,
      accounts: accounts,
      now: now,
    ),
  );
}

class _FilterSheet extends StatefulWidget {
  const _FilterSheet({
    required this.initial,
    required this.taxonomy,
    required this.accounts,
    required this.now,
  });

  final TxnFilter initial;
  final List<CategoryDef> taxonomy;
  final List<Account> accounts;
  final DateTime now;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late TxnFilter _draft = widget.initial;

  @override
  Widget build(BuildContext context) {
    final double maxHeight = MediaQuery.sizeOf(context).height * 0.85;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(Insets.xl, 0, Insets.xl, Insets.sm),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text('Filter', style: context.texts.titleLarge),
                ),
                TextButton(
                  onPressed: () => setState(() => _draft = const TxnFilter()),
                  child: const Text('Clear all'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                Insets.xl,
                Insets.lg,
                Insets.xl,
                Insets.lg,
              ),
              children: <Widget>[
                _SectionLabel('When'),
                Wrap(
                  spacing: Insets.sm,
                  runSpacing: Insets.sm,
                  children: <Widget>[
                    _choice(
                      label: 'Any time',
                      selected: _draft.from == null && _draft.to == null,
                      onSelected: () =>
                          setState(() => _draft = _draft.copyWith(clearDates: true)),
                    ),
                    _choice(
                      label: 'This month',
                      selected: _isRange(_monthStart(0), _monthStart(1)),
                      onSelected: () => _setRange(_monthStart(0), _monthStart(1)),
                    ),
                    _choice(
                      label: 'Last 3 months',
                      selected: _isRange(_monthStart(-2), _monthStart(1)),
                      onSelected: () => _setRange(_monthStart(-2), _monthStart(1)),
                    ),
                    _choice(
                      label: _customLabel(),
                      selected: _isCustom(),
                      onSelected: _pickCustomRange,
                    ),
                  ],
                ),
                const SizedBox(height: Insets.xl),
                _SectionLabel('Type'),
                Wrap(
                  spacing: Insets.sm,
                  runSpacing: Insets.sm,
                  children: <Widget>[
                    for (final CategoryKind kind in CategoryKind.values)
                      _choice(
                        label: Fmt.kind(kind),
                        selected: _draft.kinds.contains(kind),
                        onSelected: () => setState(() {
                          final Set<CategoryKind> next = <CategoryKind>{..._draft.kinds};
                          if (!next.remove(kind)) next.add(kind);
                          _draft = _draft.copyWith(kinds: next);
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: Insets.xl),
                _SectionLabel('Category'),
                if (widget.taxonomy.isEmpty)
                  Text(
                    'The category list is still loading.',
                    style: context.texts.bodySmall?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  )
                else
                  Wrap(
                    spacing: Insets.sm,
                    runSpacing: Insets.sm,
                    children: <Widget>[
                      for (final CategoryDef def in widget.taxonomy)
                        _choice(
                          label: def.name,
                          selected: _draft.categoryPaths.contains(def.id),
                          onSelected: () => setState(() {
                            final Set<String> next = <String>{..._draft.categoryPaths};
                            if (!next.remove(def.id)) next.add(def.id);
                            _draft = _draft.copyWith(categoryPaths: next);
                          }),
                        ),
                    ],
                  ),
                const SizedBox(height: Insets.xl),
                _SectionLabel('Account'),
                if (widget.accounts.isEmpty)
                  Text(
                    'No accounts have been seen yet. They appear as bank messages '
                    'arrive.',
                    style: context.texts.bodySmall?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  )
                else
                  Wrap(
                    spacing: Insets.sm,
                    runSpacing: Insets.sm,
                    children: <Widget>[
                      for (final Account account in widget.accounts)
                        _choice(
                          label: account.tail == null
                              ? account.displayName
                              : '${account.displayName} ${Fmt.maskedTail(account.tail)}',
                          selected: _draft.accountIds.contains(account.id),
                          onSelected: () => setState(() {
                            final Set<String> next = <String>{..._draft.accountIds};
                            if (!next.remove(account.id)) next.add(account.id);
                            _draft = _draft.copyWith(accountIds: next);
                          }),
                        ),
                    ],
                  ),
                const SizedBox(height: Insets.sm),
                SwitchListTile.adaptive(
                  value: _draft.onlyUncategorized,
                  onChanged: (bool value) => setState(
                    () => _draft = _draft.copyWith(onlyUncategorized: value),
                  ),
                  title: const Text('Only uncategorized'),
                  subtitle: const Text('The queue waiting for one tap each.'),
                  contentPadding: EdgeInsets.zero,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.xl,
              Insets.md,
              Insets.xl,
              Insets.xl,
            ),
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(_draft),
              child: const Text('Show results'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _choice({
    required String label,
    required bool selected,
    required VoidCallback onSelected,
  }) {
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onSelected(),
    );
  }

  DateTime _monthStart(int offset) =>
      DateTime(widget.now.year, widget.now.month + offset);

  bool _isRange(DateTime from, DateTime to) =>
      _draft.from != null &&
      _draft.to != null &&
      _draft.from!.isAtSameMomentAs(from) &&
      _draft.to!.isAtSameMomentAs(to);

  bool _isCustom() =>
      (_draft.from != null || _draft.to != null) &&
      !_isRange(_monthStart(0), _monthStart(1)) &&
      !_isRange(_monthStart(-2), _monthStart(1));

  String _customLabel() {
    if (!_isCustom()) return 'Custom';
    final DateTime? from = _draft.from;
    final DateTime? to = _draft.to;
    if (from == null || to == null) return 'Custom';
    return '${Fmt.date(from)} - ${Fmt.date(to.subtract(const Duration(days: 1)))}';
  }

  void _setRange(DateTime from, DateTime to) =>
      setState(() => _draft = _draft.copyWith(from: from, to: to));

  Future<void> _pickCustomRange() async {
    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(widget.now.year - 10),
      lastDate: widget.now,
      initialDateRange: _draft.from != null && _draft.to != null
          ? DateTimeRange(
              start: _draft.from!,
              end: _draft.to!.subtract(const Duration(days: 1)),
            )
          : null,
    );
    if (picked == null || !mounted) return;
    // The repository window is half-open, so the end day is included by adding
    // one day rather than by an inclusive comparison the caller cannot see.
    _setRange(
      DateTime(picked.start.year, picked.start.month, picked.start.day),
      DateTime(picked.end.year, picked.end.month, picked.end.day + 1),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.sm),
      child: Text(
        text,
        style: context.texts.labelLarge?.copyWith(
          color: context.colors.onSurfaceVariant,
        ),
      ),
    );
  }
}
