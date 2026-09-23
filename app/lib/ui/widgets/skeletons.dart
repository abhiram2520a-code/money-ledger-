import 'package:flutter/material.dart';

/// A single pulsing placeholder block.
///
/// Deliberately a slow opacity pulse rather than a sweeping shimmer: shimmer
/// needs a package, and a gradient sliding across the screen is harder to look
/// at than a block that breathes. Honest about being a placeholder, and gone
/// the moment real data lands.
class SkeletonBox extends StatefulWidget {
  const SkeletonBox({
    super.key,
    this.width,
    this.height = 12,
    this.radius = 6,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color base = Theme.of(context).colorScheme.onSurface;
    return FadeTransition(
      opacity: Tween<double>(begin: 0.07, end: 0.16).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
      ),
      child: Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: base,
          borderRadius: BorderRadius.circular(widget.radius),
        ),
      ),
    );
  }
}

/// A placeholder shaped like the transaction rows it is standing in for, so
/// the layout does not jump when the real rows arrive.
class SkeletonListTile extends StatelessWidget {
  const SkeletonListTile({super.key, this.showLeading = true});

  final bool showLeading;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: <Widget>[
          if (showLeading) ...<Widget>[
            const SkeletonBox(width: 40, height: 40, radius: 20),
            const SizedBox(width: 12),
          ],
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SkeletonBox(width: 150, height: 13),
                SizedBox(height: 8),
                SkeletonBox(width: 90, height: 11),
              ],
            ),
          ),
          const SizedBox(width: 12),
          const SkeletonBox(width: 64, height: 14),
        ],
      ),
    );
  }
}

/// [count] placeholder rows. The default list-loading state.
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.count = 6, this.showLeading = true});

  final int count;
  final bool showLeading;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      itemCount: count,
      itemBuilder: (BuildContext context, int index) =>
          SkeletonListTile(showLeading: showLeading),
    );
  }
}
