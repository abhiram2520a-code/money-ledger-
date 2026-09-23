import 'package:flutter/material.dart';
import 'package:ledger/models/models.dart';

/// The colours Material's [ColorScheme] does not have opinions about: money
/// moving in, money moving out, money the user moved between their own
/// accounts, and the amber that means "this needs you".
///
/// Deliberately muted. Every spend in a ledger is not an emergency, so expense
/// amounts are a warm clay rather than an error red - error red is reserved for
/// things that are actually wrong. Income is the only colour allowed to be
/// bright, because it is the rarer and more welcome event.
@immutable
class LedgerPalette extends ThemeExtension<LedgerPalette> {
  const LedgerPalette({
    required this.income,
    required this.expense,
    required this.transfer,
    required this.investment,
    required this.attention,
    required this.attentionContainer,
    required this.onAttentionContainer,
    required this.chartSeries,
    required this.chartTrack,
  });

  /// Credits the user actually earned.
  final Color income;

  /// Debits that count as spending.
  final Color expense;

  /// Movement between the user's own accounts. Reported, never counted.
  final Color transfer;

  /// Money the user still owns, parked somewhere else.
  final Color investment;

  /// The Uncategorized queue, review badges, "we could not read this".
  final Color attention;
  final Color attentionContainer;
  final Color onAttentionContainer;

  /// Fallback series for chart slices whose category defines no colour.
  final List<Color> chartSeries;

  /// The unfilled part of a donut or bar.
  final Color chartTrack;

  static const LedgerPalette light = LedgerPalette(
    income: Color(0xFF1B6B47),
    expense: Color(0xFF9A4A2F),
    transfer: Color(0xFF4A5C6A),
    investment: Color(0xFF1F6F72),
    attention: Color(0xFF8A5A00),
    attentionContainer: Color(0xFFFFEBC7),
    onAttentionContainer: Color(0xFF4A2F00),
    chartSeries: <Color>[
      Color(0xFF2E7D6B),
      Color(0xFFE08A3C),
      Color(0xFF4A78C4),
      Color(0xFFB4588A),
      Color(0xFF7A6BC4),
      Color(0xFF3F8F4F),
      Color(0xFFC0603A),
      Color(0xFF5C7A8A),
    ],
    chartTrack: Color(0xFFE2E7E5),
  );

  static const LedgerPalette dark = LedgerPalette(
    income: Color(0xFF7BD6A6),
    expense: Color(0xFFF0A98C),
    transfer: Color(0xFFAFC2CE),
    investment: Color(0xFF7CD3D0),
    attention: Color(0xFFF2C36B),
    attentionContainer: Color(0xFF3C2E10),
    onAttentionContainer: Color(0xFFFFE0A6),
    chartSeries: <Color>[
      Color(0xFF6FD3BC),
      Color(0xFFF0B070),
      Color(0xFF8FB2EE),
      Color(0xFFE79CC0),
      Color(0xFFB0A4EE),
      Color(0xFF86CE94),
      Color(0xFFEFA184),
      Color(0xFF9FB7C4),
    ],
    chartTrack: Color(0xFF2A302E),
  );

  /// The colour that stands for a whole [CategoryKind], used for amounts and
  /// for the legend when a category defines no colour of its own.
  Color forKind(CategoryKind kind) => switch (kind) {
        CategoryKind.expense => expense,
        CategoryKind.income => income,
        CategoryKind.transfer => transfer,
        CategoryKind.investment => investment,
      };

  /// A stable colour for a slice index, so the same category keeps the same
  /// colour between rebuilds.
  Color seriesAt(int index) => chartSeries[index % chartSeries.length];

  @override
  LedgerPalette copyWith({
    Color? income,
    Color? expense,
    Color? transfer,
    Color? investment,
    Color? attention,
    Color? attentionContainer,
    Color? onAttentionContainer,
    List<Color>? chartSeries,
    Color? chartTrack,
  }) {
    return LedgerPalette(
      income: income ?? this.income,
      expense: expense ?? this.expense,
      transfer: transfer ?? this.transfer,
      investment: investment ?? this.investment,
      attention: attention ?? this.attention,
      attentionContainer: attentionContainer ?? this.attentionContainer,
      onAttentionContainer: onAttentionContainer ?? this.onAttentionContainer,
      chartSeries: chartSeries ?? this.chartSeries,
      chartTrack: chartTrack ?? this.chartTrack,
    );
  }

  @override
  LedgerPalette lerp(ThemeExtension<LedgerPalette>? other, double t) {
    if (other is! LedgerPalette) return this;
    return LedgerPalette(
      income: Color.lerp(income, other.income, t) ?? income,
      expense: Color.lerp(expense, other.expense, t) ?? expense,
      transfer: Color.lerp(transfer, other.transfer, t) ?? transfer,
      investment: Color.lerp(investment, other.investment, t) ?? investment,
      attention: Color.lerp(attention, other.attention, t) ?? attention,
      attentionContainer:
          Color.lerp(attentionContainer, other.attentionContainer, t) ?? attentionContainer,
      onAttentionContainer:
          Color.lerp(onAttentionContainer, other.onAttentionContainer, t) ??
              onAttentionContainer,
      // Series colours are categorical, not continuous: blending two different
      // palettes mid-animation produces muddy slices, so snap instead.
      chartSeries: t < 0.5 ? chartSeries : other.chartSeries,
      chartTrack: Color.lerp(chartTrack, other.chartTrack, t) ?? chartTrack,
    );
  }
}

/// `context.palette` instead of `Theme.of(context).extension<LedgerPalette>()!`.
extension LedgerPaletteX on BuildContext {
  LedgerPalette get palette =>
      Theme.of(this).extension<LedgerPalette>() ??
      (Theme.of(this).brightness == Brightness.dark ? LedgerPalette.dark : LedgerPalette.light);

  ColorScheme get colors => Theme.of(this).colorScheme;

  TextTheme get texts => Theme.of(this).textTheme;
}
