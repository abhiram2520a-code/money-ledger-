import 'package:flutter/material.dart';
import 'package:ledger/models/models.dart';

import 'formatting.dart';
import 'palette.dart';
import 'tokens.dart';

/// An honest empty state: an icon, one sentence that says what is missing and
/// why, and at most one action. Never a spinner that runs forever.
class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    super.key,
    this.actionLabel,
    this.onAction,
    this.compact = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Fits inside a card instead of filling a screen.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = context.colors;
    final String? label = actionLabel;
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: Insets.xxl,
          vertical: compact ? Insets.xl : Insets.huge,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: compact ? 32 : 44, color: colors.onSurfaceVariant),
            const SizedBox(height: Insets.lg),
            Text(
              title,
              style: context.texts.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Insets.sm),
            Text(
              message,
              style: context.texts.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            if (label != null && onAction != null) ...<Widget>[
              const SizedBox(height: Insets.xl),
              OutlinedButton(
                onPressed: onAction,
                child: Text(label),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// What a screen shows when a repository call fails. Says what broke in plain
/// words and offers a retry - it never swallows the failure into an empty list,
/// because an empty ledger and a broken ledger must not look the same.
class ErrorState extends StatelessWidget {
  const ErrorState({required this.message, super.key, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.error_outline,
      title: 'Could not load this',
      message: message,
      actionLabel: onRetry == null ? null : 'Try again',
      onAction: onRetry,
    );
  }
}

/// A titled card. The dashboard is a stack of these and nothing else.
class SectionCard extends StatelessWidget {
  const SectionCard({
    required this.child,
    super.key,
    this.title,
    this.trailing,
    this.padding = Pads.card,
  });

  final Widget child;
  final String? title;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final String? heading = title;
    return Card(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (heading != null) ...<Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(heading, style: context.texts.titleMedium),
                  ),
                  ?trailing,
                ],
              ),
              const SizedBox(height: Insets.md),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

/// A rupee amount, coloured by direction and kind, with tabular digits so a
/// column of amounts lines up.
class AmountText extends StatelessWidget {
  const AmountText({
    required this.amount,
    super.key,
    this.direction,
    this.kind = CategoryKind.expense,
    this.style,
    this.showSign = true,
    this.muted = false,
  });

  final Money amount;
  final TxnDirection? direction;
  final CategoryKind kind;
  final TextStyle? style;
  final bool showSign;

  /// Transfers and excluded rows render grey: they are reported, not counted.
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final LedgerPalette palette = context.palette;
    final TxnDirection? dir = direction;
    final Color color = muted
        ? context.colors.onSurfaceVariant
        : (kind == CategoryKind.income || dir?.isCredit == true)
            ? palette.income
            : palette.forKind(kind);
    final String text = dir == null || !showSign
        ? amount.abs.format()
        : Fmt.signed(amount, dir);
    return Text(
      text,
      style: _tabular(style ?? context.texts.titleMedium).copyWith(color: color),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  static TextStyle _tabular(TextStyle? base) => (base ?? const TextStyle()).copyWith(
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      );
}

/// The round category glyph used in the transaction list and the breakdown.
class CategoryAvatar extends StatelessWidget {
  const CategoryAvatar({
    required this.categoryPath,
    required this.taxonomy,
    super.key,
    this.size = Sizes.avatar,
    this.highlight = false,
  });

  final String categoryPath;
  final List<CategoryDef> taxonomy;
  final double size;

  /// Uncategorized rows wear the attention colour so the queue is visible at a
  /// glance instead of blending into the list.
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final LedgerPalette palette = context.palette;
    final Color base = highlight
        ? palette.attention
        : CategoryLabels.color(categoryPath, taxonomy) ?? context.colors.primary;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: base.withValues(alpha: 0.14),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Icon(
        CategoryIcons.forPath(categoryPath, taxonomy),
        size: size * 0.5,
        color: base,
      ),
    );
  }
}

/// A small pill used for channel, status and filter summaries.
class MetaChip extends StatelessWidget {
  const MetaChip({required this.label, super.key, this.icon, this.tone});

  final String label;
  final IconData? icon;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final Color color = tone ?? context.colors.onSurfaceVariant;
    final IconData? glyph = icon;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.md, vertical: Insets.xs),
      decoration: BoxDecoration(
        borderRadius: Radii.pill,
        border: Border.all(color: context.colors.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (glyph != null) ...<Widget>[
            Icon(glyph, size: 14, color: color),
            const SizedBox(width: Insets.xs),
          ],
          Text(
            label,
            style: context.texts.labelMedium?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

/// The amber "this needs you" banner. Used for the Uncategorized queue and for
/// a permanently denied SMS permission.
class AttentionBanner extends StatelessWidget {
  const AttentionBanner({
    required this.title,
    required this.message,
    super.key,
    this.icon = Icons.error_outline,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String message;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final LedgerPalette palette = context.palette;
    final String? label = actionLabel;
    return Container(
      padding: Pads.cardTight,
      decoration: BoxDecoration(
        color: palette.attentionContainer,
        borderRadius: Radii.cardBorder,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: palette.onAttentionContainer, size: 20),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: context.texts.titleSmall
                      ?.copyWith(color: palette.onAttentionContainer),
                ),
                const SizedBox(height: Insets.xxs),
                Text(
                  message,
                  style: context.texts.bodySmall
                      ?.copyWith(color: palette.onAttentionContainer),
                ),
                if (label != null && onAction != null) ...<Widget>[
                  const SizedBox(height: Insets.sm),
                  TextButton(
                    onPressed: onAction,
                    style: TextButton.styleFrom(
                      foregroundColor: palette.onAttentionContainer,
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(label),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Constrains a screen's content to a comfortable reading width on tablets and
/// large phones, while staying edge-to-edge on a 320dp device.
class ContentWidth extends StatelessWidget {
  const ContentWidth({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: Sizes.maxContentWidth),
        child: child,
      ),
    );
  }
}
