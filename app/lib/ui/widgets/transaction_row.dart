import 'package:flutter/material.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/ui/theme/theme.dart';

import 'taxonomy_lookup.dart';

/// One transaction, as a compact list row.
///
/// Used by the category drill-down and by the rule preview, where the point is
/// to scan a list quickly rather than to study one transaction.
///
/// Rows that do not move net worth - transfers, investments, anything the user
/// excluded - render muted with the reason spelled out rather than hidden.
/// Hiding them is how a user ends up believing the app lost a payment.
class TransactionRow extends StatelessWidget {
  const TransactionRow({
    required this.transaction,
    required this.taxonomy,
    super.key,
    this.onTap,
    this.onLongPress,
    this.trailing,
    this.showCategory = true,
    this.selected = false,
  });

  final Transaction transaction;
  final List<CategoryDef> taxonomy;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Replaces the amount column, for selection checkboxes.
  final Widget? trailing;

  final bool showCategory;
  final bool selected;

  /// The best human name for a transaction: what the user would call it.
  ///
  /// Falls through merchant name, the raw merchant string the bank sent, then
  /// the UPI id, and only then to a generic word - never to a guess about what
  /// was bought.
  static String titleOf(Transaction txn, List<CategoryDef> taxonomy) {
    for (final String? candidate in <String?>[
      txn.merchantName,
      txn.merchantRaw,
      txn.vpa,
    ]) {
      final String value = candidate?.trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    if (!txn.isUncategorized) return shortCategoryLabel(txn.categoryPath, taxonomy);
    return txn.direction.isCredit ? 'Money in' : 'Payment';
  }

  /// The grey line under the title: when, how, and from which account.
  static String subtitleOf(Transaction txn, {required DateTime now}) {
    final String channel = Fmt.channel(txn.channel);
    final String tail = Fmt.maskedTail(txn.cardTail ?? txn.accountTail);
    return <String>[
      Fmt.dayHeading(txn.occurredAt.toLocal(), now: now),
      if (channel.isNotEmpty) channel,
      if (tail.isNotEmpty) tail,
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final Transaction txn = transaction;
    final bool muted = txn.isNetZero || txn.isExcludedFromTotals;
    final CategoryKind kind =
        kindOfPath(txn.categoryPath, taxonomy) ?? txn.kind;

    return Material(
      color: selected
          ? context.colors.secondaryContainer.withValues(alpha: 0.55)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: Pads.listRow,
          child: Row(
            children: <Widget>[
              CategoryAvatar(
                categoryPath: txn.categoryPath,
                taxonomy: taxonomy,
                highlight: txn.isUncategorized,
              ),
              const SizedBox(width: Insets.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            titleOf(txn, taxonomy),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.texts.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: muted
                                  ? context.colors.onSurfaceVariant
                                  : context.colors.onSurface,
                            ),
                          ),
                        ),
                        if (txn.needsReview) ...<Widget>[
                          const SizedBox(width: Insets.xs + 2),
                          Icon(Icons.help_outline,
                              size: 15, color: context.palette.attention),
                        ],
                      ],
                    ),
                    const SizedBox(height: Insets.xxs),
                    Text(
                      subtitleOf(txn, now: DateTime.now()),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.texts.bodySmall
                          ?.copyWith(color: context.colors.onSurfaceVariant),
                    ),
                    if (showCategory) ...<Widget>[
                      const SizedBox(height: Insets.xs),
                      Text(
                        CategoryLabels.label(txn.categoryPath, taxonomy),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.texts.labelSmall?.copyWith(
                          color: CategoryLabels.color(txn.categoryPath, taxonomy) ??
                              context.colors.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: Insets.sm),
              if (trailing != null)
                trailing!
              else
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    AmountText(
                      amount: txn.amount,
                      direction: txn.direction,
                      kind: kind,
                      muted: muted,
                      style: context.texts.bodyLarge
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (_note(txn) != null)
                      Text(
                        _note(txn)!,
                        style: context.texts.labelSmall
                            ?.copyWith(color: context.colors.onSurfaceVariant),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// The one word under the amount explaining why it may not be in the total.
  static String? _note(Transaction txn) {
    if (txn.isExcludedFromTotals) return 'excluded';
    if (txn.isNetZero) return 'not spending';
    if (txn.status == TxnStatus.pending) return 'pending';
    if (txn.status == TxnStatus.reversed) return 'refunded';
    return null;
  }
}
