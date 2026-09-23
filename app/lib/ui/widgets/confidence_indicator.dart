import 'package:flutter/material.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/ui/theme/theme.dart';

/// How sure the app is, said plainly.
///
/// The app is allowed to be unsure - that is the whole point of the review
/// queue - but it is never allowed to hide it. Three bars and one word, driven
/// by the same thresholds the categoriser uses, so what the user sees and what
/// the code decided cannot drift apart.
class ConfidenceIndicator extends StatelessWidget {
  const ConfidenceIndicator({
    required this.confidence,
    super.key,
    this.label,
    this.showLabel = true,
    this.dense = false,
  });

  /// 0.0 - 1.0.
  final double confidence;

  /// Overrides the derived word.
  final String? label;

  final bool showLabel;
  final bool dense;

  /// The word for a confidence value. Public so a screen can put the same word
  /// in a sentence without re-deriving the thresholds.
  static String wordFor(double confidence) {
    if (confidence >= CategoryResult.dictionaryConfidence) return 'Certain';
    if (confidence >= CategoryResult.autoApplyThreshold) return 'Likely';
    if (confidence > 0) return 'Unsure';
    return 'Unknown';
  }

  static int _litBars(double confidence) {
    if (confidence >= CategoryResult.dictionaryConfidence) return 3;
    if (confidence >= CategoryResult.autoApplyThreshold) return 2;
    if (confidence > 0) return 1;
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final int lit = _litBars(confidence);
    final Color on = switch (lit) {
      3 => context.palette.income,
      2 => context.colors.primary,
      _ => context.palette.attention,
    };
    final Color off = context.colors.outlineVariant;
    final double barWidth = dense ? 3 : 4;
    final double unit = dense ? 5 : 6;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < 3; i++)
          Container(
            width: barWidth,
            height: unit + unit * 0.45 * i,
            margin: EdgeInsets.only(right: i == 2 ? 0 : 2),
            decoration: BoxDecoration(
              color: i < lit ? on : off,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        if (showLabel) ...<Widget>[
          const SizedBox(width: Insets.xs + 2),
          Text(
            label ?? wordFor(confidence),
            style: (dense ? context.texts.labelSmall : context.texts.labelMedium)
                ?.copyWith(color: on, fontWeight: FontWeight.w600),
          ),
        ],
      ],
    );
  }
}

/// Why the app chose a category, in the app's own words.
///
/// `CategoryResult.explanation` and `Transaction.categoryExplanation` are
/// already human sentences by contract; this gives them one quiet, consistent
/// presentation with a glyph for where the decision came from. A category the
/// user cannot explain is a category the user cannot trust or correct.
class CategoryExplanation extends StatelessWidget {
  const CategoryExplanation({
    required this.explanation,
    super.key,
    this.source,
    this.maxLines = 3,
  });

  final String explanation;
  final CategorySource? source;
  final int maxLines;

  static IconData iconForSource(CategorySource? source) => switch (source) {
        CategorySource.manual => Icons.person_outline,
        CategorySource.userRule => Icons.auto_awesome_outlined,
        CategorySource.dictionary => Icons.menu_book_outlined,
        CategorySource.vpa => Icons.alternate_email,
        CategorySource.channel => Icons.alt_route,
        CategorySource.parserRule => Icons.rule_folder_outlined,
        CategorySource.unknown => Icons.help_outline,
        null => Icons.help_outline,
      };

  @override
  Widget build(BuildContext context) {
    if (explanation.trim().isEmpty) return const SizedBox.shrink();
    final Color muted = context.colors.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(iconForSource(source), size: 14, color: muted),
        ),
        const SizedBox(width: Insets.xs + 2),
        Expanded(
          child: Text(
            explanation,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            style: context.texts.bodySmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}
