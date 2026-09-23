import 'package:flutter/material.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/ui/theme/theme.dart';

/// The sticky-looking date heading above a day's rows.
class DayHeader extends StatelessWidget {
  const DayHeader({required this.label, required this.total, super.key});

  final String label;

  /// Net spend for the day, already computed by the caller.
  final Money total;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: context.colors.surface,
      padding: const EdgeInsets.fromLTRB(
        Insets.page,
        Insets.lg,
        Insets.page,
        Insets.sm,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: context.texts.labelLarge?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ),
          Text(
            Fmt.moneyWhole(total),
            style: AppTheme.tabular(context.texts.labelLarge)
                .copyWith(color: context.colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
