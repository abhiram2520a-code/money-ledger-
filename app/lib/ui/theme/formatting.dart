import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:ledger/models/models.dart';

/// Currency, date and label formatting for the UI layer.
///
/// Currency formatting is delegated to [Money.format] on purpose: it is the one
/// place that knows about lakh/crore grouping and about paise-as-int. Nothing
/// in the UI is allowed to turn money into a `double` and hand it to
/// `NumberFormat`, which would both round wrongly and group in thousands.
abstract final class Fmt {
  /// `Rs 1,24,500.00`
  static String money(Money amount) => amount.format();

  /// The dashboard form. Paise on a monthly total is noise.
  static String moneyWhole(Money amount) => amount.format(decimals: false);

  /// `1.25L` style - for chart labels and anywhere the column is narrow.
  static String moneyCompact(Money amount) => amount.formatCompact();

  /// `- 450.00` / `+ 12,000.00` with the currency symbol. The space after the
  /// sign is deliberate: it keeps the rupee symbol readable at 12sp.
  static String signed(Money amount, TxnDirection direction) {
    final String sign = direction.isDebit ? '-' : '+';
    return '$sign ${amount.abs.format()}';
  }

  /// `September 2026`
  static String month(DateTime month) => _monthYear.format(month);

  /// `Sep 2026` - for the month strip.
  static String monthShort(DateTime month) => _monthShort.format(month);

  /// `23 Sep 2026`
  static String date(DateTime at) => _date.format(at.toLocal());

  /// `23 Sep 2026, 4:05 PM`
  static String dateTime(DateTime at) => _dateTime.format(at.toLocal());

  /// `4:05 PM`
  static String time(DateTime at) => _time.format(at.toLocal());

  /// The heading above a day's group of transactions: `Today`, `Yesterday`,
  /// `Mon, 21 Sep`, or `21 Sep 2025` once the year stops being obvious.
  static String dayHeading(DateTime day, {required DateTime now}) {
    final DateTime d = DateTime(day.year, day.month, day.day);
    final DateTime today = DateTime(now.year, now.month, now.day);
    final int diff = today.difference(d).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    if (d.year == today.year) return _dayInYear.format(d);
    return _date.format(d);
  }

  /// Turns a `'YYYY-MM-DD'` booking date back into a local [DateTime]. Returns
  /// `null` rather than throwing on anything malformed, because a corrupt row
  /// must not take the list down.
  static DateTime? parseBookingDate(String bookingDate) {
    final List<String> parts = bookingDate.split('-');
    if (parts.length != 3) return null;
    final int? y = int.tryParse(parts[0]);
    final int? m = int.tryParse(parts[1]);
    final int? d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    if (m < 1 || m > 12 || d < 1 || d > 31) return null;
    return DateTime(y, m, d);
  }

  /// `HDFC ..1234` - the account line under a transaction. The tail is already
  /// masked in the SMS; this never reconstructs more digits than the bank sent.
  static String maskedTail(String? tail, {String? issuer}) {
    final String? normalized = Account.normalizeTail(tail);
    if (normalized == null) return issuer ?? '';
    final String masked = '••$normalized';
    return issuer == null || issuer.isEmpty ? masked : '$issuer $masked';
  }

  /// `UPI`, `Card`, `Net banking`, ... for a channel chip.
  static String channel(TxnChannel channel) => switch (channel) {
        TxnChannel.upi => 'UPI',
        TxnChannel.card => 'Card',
        TxnChannel.netbanking => 'Net banking',
        TxnChannel.atm => 'ATM',
        TxnChannel.nach => 'Auto-debit',
        TxnChannel.impsNeft => 'IMPS / NEFT',
        TxnChannel.cash => 'Cash',
        TxnChannel.unknown => 'Other',
      };

  static String kind(CategoryKind kind) => switch (kind) {
        CategoryKind.expense => 'Expense',
        CategoryKind.income => 'Income',
        CategoryKind.transfer => 'Transfer',
        CategoryKind.investment => 'Investment',
      };

  static String status(TxnStatus status) => switch (status) {
        TxnStatus.posted => 'Posted',
        TxnStatus.pending => 'Pending',
        TxnStatus.needsReview => 'Needs review',
        TxnStatus.reversed => 'Reversed',
        TxnStatus.voided => 'Cancelled',
      };

  static String accountType(AccountType type) => switch (type) {
        AccountType.savings => 'Savings account',
        AccountType.current => 'Current account',
        AccountType.creditCard => 'Credit card',
        AccountType.wallet => 'Wallet',
        AccountType.cash => 'Cash',
        AccountType.loan => 'Loan',
        AccountType.investment => 'Investment account',
        AccountType.unknown => 'Account',
      };

  /// The one-line reason shown under a category on the detail screen.
  static String categorySource(CategorySource source) => switch (source) {
        CategorySource.dictionary => 'Matched the built-in merchant list',
        CategorySource.vpa => 'Matched the UPI ID',
        CategorySource.channel => 'Inferred from how the money moved',
        CategorySource.parserRule => 'Set by the bank message rule',
        CategorySource.userRule => 'Your own rule',
        CategorySource.manual => 'You chose this',
        CategorySource.unknown => 'Nothing matched - waiting for you',
      };

  /// Plain integer grouping, Indian style, for message counters.
  static String count(int value) => Money.groupIndian(value);

  /// `1,284 messages` / `1 message`.
  static String plural(int value, String singular, String pluralForm) =>
      '${count(value)} ${value == 1 ? singular : pluralForm}';

  static final DateFormat _monthYear = DateFormat('MMMM yyyy');
  static final DateFormat _monthShort = DateFormat('MMM yyyy');
  static final DateFormat _date = DateFormat('d MMM yyyy');
  static final DateFormat _dateTime = DateFormat('d MMM yyyy, h:mm a');
  static final DateFormat _time = DateFormat('h:mm a');
  static final DateFormat _dayInYear = DateFormat('EEE, d MMM');
}

/// Maps the `icon` strings in `rules/categories.json` onto Material icons.
///
/// The map is exhaustive for the shipped taxonomy and falls back to a neutral
/// glyph, so a rules update that introduces a new icon name renders a circle
/// rather than crashing.
abstract final class CategoryIcons {
  static const IconData fallback = Icons.category_outlined;
  static const IconData uncategorized = Icons.help_outline;

  static const Map<String, IconData> _byName = <String, IconData>{
    'restaurant': Icons.restaurant_outlined,
    'shopping_basket': Icons.shopping_basket_outlined,
    'directions_car': Icons.directions_car_outlined,
    'flight': Icons.flight_outlined,
    'shopping_bag': Icons.shopping_bag_outlined,
    'movie': Icons.movie_outlined,
    'receipt_long': Icons.receipt_long_outlined,
    'favorite': Icons.favorite_outline,
    'school': Icons.school_outlined,
    'home': Icons.home_outlined,
    'account_balance': Icons.account_balance_outlined,
    'shield': Icons.shield_outlined,
    'gavel': Icons.gavel_outlined,
    'group': Icons.group_outlined,
    'more_horiz': Icons.more_horiz,
    'trending_up': Icons.trending_up,
    'swap_horiz': Icons.swap_horiz,
    'savings': Icons.savings_outlined,
    'help_outline': Icons.help_outline,
  };

  static IconData forName(String? name) => _byName[name] ?? fallback;

  /// The icon for a category path, resolved against the loaded taxonomy.
  static IconData forPath(String categoryPath, List<CategoryDef> taxonomy) {
    if (categoryPath == CategoryResult.uncategorizedPath) return uncategorized;
    final (String categoryId, _) = CategoryDef.splitPath(categoryPath);
    for (final CategoryDef def in taxonomy) {
      if (def.id == categoryId) return forName(def.icon);
    }
    return fallback;
  }
}

/// Human labels for category paths, resolved against the loaded taxonomy.
abstract final class CategoryLabels {
  /// `Food & Dining - Food Delivery`, or just `Food & Dining` for a bare path.
  /// Falls back to the raw path so an unknown category is still legible.
  static String label(String categoryPath, List<CategoryDef> taxonomy) {
    if (categoryPath == CategoryResult.uncategorizedPath) return 'Uncategorized';
    final (String categoryId, String? subId) = CategoryDef.splitPath(categoryPath);
    for (final CategoryDef def in taxonomy) {
      if (def.id != categoryId) continue;
      if (subId == null) return def.name;
      final SubcategoryDef? sub = def.subcategory(subId);
      return sub == null ? def.name : '${def.name} · ${sub.name}';
    }
    return _humanize(categoryPath);
  }

  /// Just the top-level name: `Food & Dining`.
  static String topLevel(String categoryPath, List<CategoryDef> taxonomy) {
    if (categoryPath == CategoryResult.uncategorizedPath) return 'Uncategorized';
    final (String categoryId, _) = CategoryDef.splitPath(categoryPath);
    for (final CategoryDef def in taxonomy) {
      if (def.id == categoryId) return def.name;
    }
    return _humanize(categoryId);
  }

  /// The colour a category declares in `categories.json`, if any.
  static Color? color(String categoryPath, List<CategoryDef> taxonomy) {
    final (String categoryId, _) = CategoryDef.splitPath(categoryPath);
    for (final CategoryDef def in taxonomy) {
      if (def.id != categoryId) continue;
      final int? value = def.colorValue;
      return value == null ? null : Color(value);
    }
    return null;
  }

  static String _humanize(String raw) {
    if (raw.isEmpty) return 'Other';
    return raw
        .replaceAll('/', ' · ')
        .replaceAll('_', ' ')
        .split(' ')
        .map((String w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
  }
}
