/// Shared components that sit on top of the design system in
/// `lib/ui/theme/`, for the parts of the app that ask the user something:
/// the review queue, the category browser, the rule editor and settings.
///
/// ```dart
/// import 'package:ledger/ui/theme/theme.dart';
/// import 'package:ledger/ui/widgets/widgets.dart';
/// ```
///
/// The two are complementary and never overlap: `theme/` owns tokens, themes,
/// formatting and the primitives (`EmptyState`, `AmountText`,
/// `CategoryAvatar`, `MetaChip`), and this library owns the pieces that only
/// exist because the app asks instead of guessing - the category picker, the
/// confidence indicator, the source-SMS card.
library;

export 'category_chip.dart';
export 'category_picker.dart';
export 'confidence_indicator.dart';
export 'skeletons.dart';
export 'source_sms_card.dart';
export 'taxonomy_lookup.dart';
export 'transaction_row.dart';
