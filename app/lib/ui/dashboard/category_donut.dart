import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/ui/theme/theme.dart';

/// One slice of the breakdown.
@immutable
class DonutSlice {
  const DonutSlice({
    required this.label,
    required this.amount,
    required this.color,
    this.categoryPath,
  });

  final String label;
  final Money amount;
  final Color color;
  final String? categoryPath;
}

/// A plain donut chart, drawn with a [CustomPainter] rather than a charting
/// package.
///
/// Two reasons it is hand-drawn: the app ships no chart dependency (every
/// dependency is a supply-chain question for an app whose pitch is privacy),
/// and the only chart this screen needs is one ring with a total in the middle.
///
/// Slices below one percent are folded into the last slice rather than drawn as
/// invisible hairlines, so the ring always adds up to what the legend says.
class CategoryDonut extends StatelessWidget {
  const CategoryDonut({
    required this.slices,
    required this.total,
    super.key,
    this.centerLabel = 'spent',
    this.size = Sizes.donut,
  });

  final List<DonutSlice> slices;
  final Money total;
  final String centerLabel;
  final double size;

  @override
  Widget build(BuildContext context) {
    final LedgerPalette palette = context.palette;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _DonutPainter(
          slices: slices,
          trackColor: palette.chartTrack,
          strokeWidth: Sizes.donutStroke,
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                Fmt.moneyCompact(total),
                style: AppTheme.tabular(context.texts.headlineSmall),
                maxLines: 1,
              ),
              Text(
                centerLabel,
                style: context.texts.labelMedium?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  const _DonutPainter({
    required this.slices,
    required this.trackColor,
    required this.strokeWidth,
  });

  final List<DonutSlice> slices;
  final Color trackColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final double radius = (math.min(size.width, size.height) - strokeWidth) / 2;
    final Offset center = Offset(size.width / 2, size.height / 2);
    final Rect rect = Rect.fromCircle(center: center, radius: radius);

    final Paint track = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawCircle(center, radius, track);

    int totalPaise = 0;
    for (final DonutSlice slice in slices) {
      totalPaise += slice.amount.paise.abs();
    }
    if (totalPaise <= 0) return;

    // Start at 12 o'clock and go clockwise, which is how a reader expects a
    // share-of-total ring to be laid out.
    double start = -math.pi / 2;
    const double gap = 0.02;
    for (int i = 0; i < slices.length; i++) {
      final DonutSlice slice = slices[i];
      final double fraction = slice.amount.paise.abs() / totalPaise;
      final double sweep = fraction * math.pi * 2;
      if (sweep <= 0) continue;
      final Paint paint = Paint()
        ..color = slice.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.butt;
      // Leave a hairline gap between slices, but never let the gap eat a slice
      // that is genuinely small.
      final double drawn = slices.length == 1 ? sweep : math.max(sweep - gap, sweep * 0.6);
      canvas.drawArc(rect, start, drawn, false, paint);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter oldDelegate) =>
      oldDelegate.trackColor != trackColor ||
      oldDelegate.strokeWidth != strokeWidth ||
      !_sameSlices(oldDelegate.slices, slices);

  static bool _sameSlices(List<DonutSlice> a, List<DonutSlice> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].amount.paise != b[i].amount.paise || a[i].color != b[i].color) {
        return false;
      }
    }
    return true;
  }
}

/// The legend beside the donut: colour, category, amount, share.
class DonutLegend extends StatelessWidget {
  const DonutLegend({
    required this.slices,
    required this.total,
    super.key,
    this.onTap,
  });

  final List<DonutSlice> slices;
  final Money total;
  final void Function(DonutSlice slice)? onTap;

  @override
  Widget build(BuildContext context) {
    final int totalPaise = total.paise.abs();
    return Column(
      children: <Widget>[
        for (final DonutSlice slice in slices)
          InkWell(
            onTap: onTap == null ? null : () => onTap!(slice),
            borderRadius: Radii.fieldBorder,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Insets.sm),
              child: Row(
                children: <Widget>[
                  Container(
                    width: Sizes.categoryDot,
                    height: Sizes.categoryDot,
                    decoration: BoxDecoration(
                      color: slice.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: Insets.md),
                  Expanded(
                    child: Text(
                      slice.label,
                      style: context.texts.bodyMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: Insets.sm),
                  Text(
                    Fmt.moneyWhole(slice.amount),
                    style: AppTheme.tabular(context.texts.bodyMedium),
                  ),
                  SizedBox(
                    width: 48,
                    child: Text(
                      totalPaise == 0
                          ? ''
                          : '${(slice.amount.paise.abs() * 100 / totalPaise).round()}%',
                      style: context.texts.bodySmall?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.right,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
