import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ledger/core/result.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/ui/theme/theme.dart';
import 'package:ledger/ui/widgets/widgets.dart';

import 'rules_controller.dart';

/// Opens the rule editor for [rule].
Future<void> showEditRuleSheet(BuildContext context, {required UserRule rule}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (BuildContext sheetContext) => EditRuleSheet(rule: rule),
  );
}

/// Change a rule the app learned, or undo its effect on what is already filed.
///
/// The screen is deliberately explicit about what changes and what does not.
/// Saving changes future messages. Sweeping is a separate button with its own
/// count, because rewriting a month of history is not something that should
/// happen as a side effect of editing a text field.
class EditRuleSheet extends ConsumerStatefulWidget {
  const EditRuleSheet({required this.rule, super.key});

  final UserRule rule;

  @override
  ConsumerState<EditRuleSheet> createState() => _EditRuleSheetState();
}

class _EditRuleSheetState extends ConsumerState<EditRuleSheet> {
  late final TextEditingController _pattern =
      TextEditingController(text: widget.rule.pattern);
  late final TextEditingController _name =
      TextEditingController(text: widget.rule.merchantName ?? '');

  late UserRuleMatch _match = widget.rule.match;
  late String _categoryPath = widget.rule.categoryPath;
  late CategoryKind _kind = widget.rule.kind;
  late bool _enabled = widget.rule.enabled;

  int? _sweepCount;
  bool _counting = false;

  @override
  void dispose() {
    _pattern.dispose();
    _name.dispose();
    super.dispose();
  }

  UserRule get _edited => widget.rule.copyWith(
        match: _match,
        pattern: _pattern.text.trim(),
        categoryPath: _categoryPath,
        kind: _kind,
        merchantName: _name.text.trim(),
        enabled: _enabled,
        updatedAt: ref.read(clockProvider)(),
      );

  static String labelFor(UserRuleMatch match) => switch (match) {
        UserRuleMatch.merchantExact => 'Payee is exactly this',
        UserRuleMatch.merchantContains => 'Payee contains this',
        UserRuleMatch.vpaExact => 'UPI ID is exactly this',
        UserRuleMatch.vpaPrefix => 'UPI ID starts with this',
        UserRuleMatch.senderExact => 'SMS sender is this',
        UserRuleMatch.bodyContains => 'Message contains this',
      };

  Future<void> _pickCategory() async {
    final CategoryPick? pick = await showCategoryPicker(
      context,
      taxonomy: ref.read(taxonomyProvider),
      title: 'File these under',
      currentPath: _categoryPath,
    );
    if (pick == null) return;
    setState(() {
      _categoryPath = pick.path;
      _kind = pick.kind;
      _sweepCount = null;
    });
  }

  Future<void> _countSweep() async {
    setState(() => _counting = true);
    final List<Transaction> matches =
        await ref.read(rulesControllerProvider.notifier).preview(_edited);
    if (!mounted) return;
    setState(() {
      _counting = false;
      _sweepCount = matches.length;
    });
  }

  Future<void> _sweep() async {
    final int changed =
        await ref.read(rulesControllerProvider.notifier).applyToExisting(_edited);
    if (!mounted) return;
    setState(() => _sweepCount = 0);
    _snack(changed == 0
        ? 'Nothing needed changing.'
        : '${Fmt.plural(changed, 'transaction', 'transactions')} moved to '
            '${CategoryLabels.label(_categoryPath, ref.read(taxonomyProvider))}.');
  }

  Future<void> _save() async {
    final Result<UserRule> result =
        await ref.read(rulesControllerProvider.notifier).save(_edited);
    if (!mounted) return;
    if (result.isErr) {
      _snack('Could not save: ${result.errorOrNull?.message ?? 'unknown error'}');
      return;
    }
    Navigator.of(context).pop();
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final List<CategoryDef> taxonomy = ref.watch(taxonomyProvider);
    final bool busy = ref.watch(rulesControllerProvider);
    final bool sweepable = _match != UserRuleMatch.senderExact &&
        _match != UserRuleMatch.bodyContains;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (BuildContext context, ScrollController controller) {
        return ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(
              Insets.xl, 0, Insets.xl, Insets.xxxl),
          children: <Widget>[
            Text('Edit rule', style: context.texts.titleLarge),
            const SizedBox(height: Insets.xs),
            Text(
              'Created ${Fmt.date(widget.rule.createdAt)}'
              '${widget.rule.hitCount > 0 ? ' · used ${Fmt.plural(widget.rule.hitCount, 'time', 'times')}' : ''}',
              style: context.texts.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
            const SizedBox(height: Insets.xl),

            Text('File under', style: context.texts.labelLarge),
            const SizedBox(height: Insets.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: CategoryChip(
                categoryPath: _categoryPath,
                taxonomy: taxonomy,
                onTap: busy ? null : _pickCategory,
              ),
            ),
            const SizedBox(height: Insets.xl),

            Text('Match on', style: context.texts.labelLarge),
            const SizedBox(height: Insets.sm),
            DropdownButtonFormField<UserRuleMatch>(
              initialValue: _match,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(borderRadius: Radii.fieldBorder),
              ),
              items: <DropdownMenuItem<UserRuleMatch>>[
                for (final UserRuleMatch m in UserRuleMatch.values)
                  DropdownMenuItem<UserRuleMatch>(
                    value: m,
                    child: Text(labelFor(m)),
                  ),
              ],
              onChanged: busy
                  ? null
                  : (UserRuleMatch? m) => setState(() {
                        if (m != null) _match = m;
                        _sweepCount = null;
                      }),
            ),
            const SizedBox(height: Insets.md),
            TextField(
              controller: _pattern,
              onChanged: (String _) => setState(() => _sweepCount = null),
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Text to match',
                helperText: 'Matched without case. Not a regular expression.',
                border: OutlineInputBorder(borderRadius: Radii.fieldBorder),
              ),
            ),
            const SizedBox(height: Insets.md),
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Show this payee as',
                helperText: 'Optional. The name you would recognise.',
                border: OutlineInputBorder(borderRadius: Radii.fieldBorder),
              ),
            ),
            const SizedBox(height: Insets.md),
            SwitchListTile(
              value: _enabled,
              onChanged: busy ? null : (bool on) => setState(() => _enabled = on),
              contentPadding: EdgeInsets.zero,
              title: const Text('Rule is on'),
              subtitle: const Text(
                  'Turning it off keeps the rule but stops it applying.'),
            ),
            const Divider(height: Insets.xxl),

            Text('Transactions already recorded',
                style: context.texts.labelLarge),
            const SizedBox(height: Insets.xs),
            Text(
              sweepable
                  ? 'Saving only affects new messages. You can also apply this '
                      'rule to what is already in the ledger - anything you '
                      'categorised by hand is left alone.'
                  : 'This rule matches on the message itself, which the ledger '
                      'does not keep alongside a transaction, so it can only '
                      'apply to new messages.',
              style: context.texts.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
            if (sweepable) ...<Widget>[
              const SizedBox(height: Insets.md),
              if (_sweepCount == null)
                OutlinedButton.icon(
                  onPressed: busy || _counting ? null : _countSweep,
                  icon: _counting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search, size: 18),
                  label: const Text('Check what this would change'),
                )
              else if (_sweepCount == 0)
                Text(
                  'Nothing already recorded would change.',
                  style: context.texts.bodyMedium,
                )
              else
                FilledButton.tonalIcon(
                  onPressed: busy ? null : _sweep,
                  icon: const Icon(Icons.history, size: 18),
                  label: Text(
                    'Move ${Fmt.plural(_sweepCount!, 'transaction', 'transactions')}',
                  ),
                ),
            ],

            const SizedBox(height: Insets.xxl),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                    onPressed: busy ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: Insets.md),
                Expanded(
                  child: FilledButton(
                    onPressed: busy || _pattern.text.trim().isEmpty ? null : _save,
                    child: const Text('Save'),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
