import 'package:flutter/widgets.dart';

/// Spacing scale. One ladder for the whole app, so a card in the dashboard and
/// a row in the transaction list breathe the same way.
///
/// The steps are 4dp-based because Material's own components are, and mixing a
/// 5dp scale with an 8dp component library is what makes a finance app look
/// improvised.
abstract final class Insets {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
  static const double huge = 48;

  /// Horizontal page margin. Every full-width screen uses this and nothing else.
  static const double page = 16;
}

/// Ready-made [EdgeInsets] for the cases that come up on every screen.
abstract final class Pads {
  static const EdgeInsets page = EdgeInsets.symmetric(horizontal: Insets.page);
  static const EdgeInsets card = EdgeInsets.all(Insets.lg);
  static const EdgeInsets cardTight = EdgeInsets.symmetric(
    horizontal: Insets.lg,
    vertical: Insets.md,
  );
  static const EdgeInsets listRow = EdgeInsets.symmetric(
    horizontal: Insets.page,
    vertical: Insets.md,
  );
  static const EdgeInsets sheet = EdgeInsets.fromLTRB(
    Insets.xl,
    Insets.lg,
    Insets.xl,
    Insets.xxl,
  );

  /// Bottom padding for a scroll view that sits under a floating action button
  /// or a bottom bar, so the last row is never trapped behind it.
  static const EdgeInsets scrollTail = EdgeInsets.only(bottom: 96);
}

/// Corner radii. Cards are soft, chips are pill-shaped, sheets are top-rounded.
abstract final class Radii {
  static const Radius chip = Radius.circular(999);
  static const double card = 16;
  static const double field = 12;
  static const double sheet = 28;

  static const BorderRadius cardBorder = BorderRadius.all(Radius.circular(card));
  static const BorderRadius fieldBorder = BorderRadius.all(Radius.circular(field));
  static const BorderRadius pill = BorderRadius.all(chip);
  static const BorderRadius sheetBorder = BorderRadius.vertical(top: Radius.circular(sheet));
}

/// Animation durations. Deliberately short: this app shows numbers, and a
/// number that slides into place slowly reads as a number the app is unsure of.
abstract final class Motion {
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration normal = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 400);

  /// How long an import progress counter waits before it animates to a new
  /// value, so a fast backfill does not strobe.
  static const Duration counterTick = Duration(milliseconds: 300);
}

/// Layout constants that are not spacing.
abstract final class Sizes {
  /// Widest a reading column ever gets, so the app is usable on a tablet
  /// without the text turning into a ribbon.
  static const double maxContentWidth = 560;

  static const double categoryDot = 10;
  static const double avatar = 40;
  static const double donut = 180;
  static const double donutStroke = 26;

  /// Rows rendered beyond the viewport before the pager asks for another page.
  static const int pagePrefetchRows = 12;

  /// Transactions fetched per page. Large enough that a fast scroll does not
  /// stutter, small enough that the first page lands instantly.
  static const int pageSize = 60;
}
