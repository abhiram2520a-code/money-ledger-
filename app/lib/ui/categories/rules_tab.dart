import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ledger/core/result.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/ui/theme/theme.dart';
import 'package:ledger/ui/widgets/widgets.dart';

import 'categories_controller.dart';
import 'edit_rule_sheet.dart';
import 'rules_controller.dart';

/// Everything the app has learned from this user, in one list.
///
/// A learned rule is a decision made once and repeated forever, so it has to
/// be findable and reversible. Every rule here can be switched off, edited or
/// deleted, and the list says in plain words what each one does and how many
/// transactions it has filed.
class RulesTab extends ConsumerWidget {
  const RulesTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<UserRule>> async = ref.watch(userRulesProvider);
    final List<UserRule> rules = ref.watch(sortedUserRulesProvider);
    final List<CategoryDef> taxonomy = ref.watch(taxonomyProvider);

    return async.when(
      loading: () => const SkeletonList(count: 4),
      error: (Object _, StackTrace _) => ErrorState(
        message: 'Your rules could not be read from the local database.',
        onRetry: () => ref.invalidate(userRulesProvider),
      ),
      data: (List<UserRule> _) {
        if (rules.isEmpty) return const _NoRulesYet();
        return ContentWidth(
          child: ListView.separated(
            padding: const EdgeInsets.only(bottom: Insets.huge),
            itemCount: rules.length + 1,
            separatorBuilder: (BuildContext context, int i) =>
                i == 0 ? const SizedBox.shrink() : const Divider(height: 1),
            itemBuilder: (BuildContext context, int i) {
              if (i == 0) return const _RulesPreamble();
              final UserRule rule = rules[i - 1];
              return _RuleRow(
                key: ValueKey<String>(rule.id),
                rule: rule,
                taxonomy: taxonomy,
              );
            },
          ),
        );
      },
    );
  }
}

class _NoRulesYet extends StatelessWidget {
  const _NoRulesYet();

  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: Icons.auto_awesome_outlined,
      title: 'No rules yet',
      message: 'When you give a category to an unknown payee in Review, the '
          'app saves that choice here so it never has to ask again. Nothing '
          'is learned anywhere else, and nothing leaves this phone.',
    );
  }
}

class _RulesPreamble extends StatelessWidget {
  const _RulesPreamble();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          Insets.lg, Insets.lg, Insets.lg, Insets.md),
      child: Text(
        'Your rules beat the merchant list built into the app, and a rules '
        'update never overwrites them.',
        style: context.texts.bodySmall
            ?.copyWith(color: context.colors.onSurfaceVariant),
      ),
    );
  }
}

class _RuleRow extends ConsumerWidget {
  const _RuleRow({required this.rule, required this.taxonomy, super.key});

  final UserRule rule;
  final List<CategoryDef> taxonomy;

  Future<void> _toggle(BuildContext context, WidgetRef ref, bool on) async {
    final Result<UserRule> result =
        await ref.read(rulesControllerProvider.notifier).setEnabled(rule, on);
    if (!context.mounted) return;
    if (result.isErr) {
      _snack(context, 'Could not change the rule: ${result.errorOrNull?.message}');
    }
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Delete this rule?'),
        content: Text(
          'The app will stop applying it to new messages. The '
          '${Fmt.plural(rule.hitCount, 'transaction', 'transactions')} it has '
          'already filed keep their category.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (yes != true || !context.mounted) return;
    final Result<void> result =
        await ref.read(rulesControllerProvider.notifier).delete(rule.id);
    if (!context.mounted) return;
    _snack(
      context,
      result.isOk
          ? 'Rule deleted.'
          : 'Could not delete the rule: ${result.errorOrNull?.message}',
    );
  }

  static void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool busy = ref.watch(rulesControllerProvider);
    final String title = (rule.merchantName?.trim().isNotEmpty ?? false)
        ? rule.merchantName!.trim()
        : rule.pattern;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
          horizontal: Insets.lg, vertical: Insets.xs),
      leading: CategoryAvatar(
        categoryPath: rule.categoryPath,
        taxonomy: taxonomy,
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: context.texts.bodyLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: rule.enabled
              ? context.colors.onSurface
              : context.colors.onSurfaceVariant,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SizedBox(height: Insets.xxs),
          Text(
            '→ ${CategoryLabels.label(rule.categoryPath, taxonomy)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.texts.bodySmall,
          ),
          const SizedBox(height: Insets.xxs),
          Text(
            <String>[
              rule.explanation,
              if (rule.hitCount > 0)
                'used ${Fmt.plural(rule.hitCount, 'time', 'times')}',
              if (!rule.enabled) 'off',
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: context.texts.labelSmall
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
        ],
      ),
      isThreeLine: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Switch(
            value: rule.enabled,
            onChanged: busy ? null : (bool on) => _toggle(context, ref, on),
          ),
          PopupMenuButton<String>(
            tooltip: 'Rule options',
            onSelected: (String value) {
              if (value == 'edit') {
                showEditRuleSheet(context, rule: rule);
              } else if (value == 'delete') {
                _confirmDelete(context, ref);
              }
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              const PopupMenuItem<String>(value: 'edit', child: Text('Edit')),
              const PopupMenuItem<String>(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
      onTap: () => showEditRuleSheet(context, rule: rule),
    );
  }
}
