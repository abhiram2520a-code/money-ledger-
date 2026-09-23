import 'package:flutter/material.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/ui/theme/theme.dart';

/// The message a transaction came from, shown verbatim.
///
/// This is the app's receipt. When the user is asked "what is PAYTM-53412?",
/// the honest answer is the SMS itself, so they decide from exactly the
/// evidence the parser had.
///
/// PRIVACY: [RawMessage.body] is the only field in the app that holds message
/// text. It is read here and rendered, and nothing else - never logged, never
/// attached to an error, never sent anywhere. The footer line says so, because
/// a privacy promise the user cannot see is not a promise.
class SourceSmsCard extends StatefulWidget {
  const SourceSmsCard({
    required this.message,
    super.key,
    this.initiallyExpanded = true,
    this.showPrivacyNote = true,
  });

  final RawMessage message;
  final bool initiallyExpanded;
  final bool showPrivacyNote;

  @override
  State<SourceSmsCard> createState() => _SourceSmsCardState();
}

class _SourceSmsCardState extends State<SourceSmsCard> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final RawMessage m = widget.message;
    final String header = (m.senderHeader ?? m.senderRaw).trim();
    final String sender = header.isEmpty ? 'Unknown sender' : header;
    final Color muted = context.colors.onSurfaceVariant;

    return Container(
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerHighest,
        borderRadius: Radii.cardBorder,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  Insets.md, Insets.sm + 2, Insets.sm, Insets.sm + 2),
              child: Row(
                children: <Widget>[
                  Icon(Icons.sms_outlined, size: 16, color: muted),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Text(
                      sender,
                      overflow: TextOverflow.ellipsis,
                      style: context.texts.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                  const SizedBox(width: Insets.sm),
                  Text(
                    Fmt.dateTime(m.receivedAt),
                    style: context.texts.labelSmall?.copyWith(color: muted),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: muted,
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: Motion.fast,
            firstCurve: Curves.easeOut,
            secondCurve: Curves.easeOut,
            sizeCurve: Curves.easeOut,
            crossFadeState:
                _expanded ? CrossFadeState.showFirst : CrossFadeState.showSecond,
            firstChild: Padding(
              padding: const EdgeInsets.fromLTRB(
                  Insets.md, 0, Insets.md, Insets.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SelectableText(
                    m.body,
                    style: context.texts.bodyMedium?.copyWith(height: 1.35),
                  ),
                  if (widget.showPrivacyNote) ...<Widget>[
                    const SizedBox(height: Insets.sm + 2),
                    Row(
                      children: <Widget>[
                        Icon(Icons.lock_outline, size: 13, color: muted),
                        const SizedBox(width: Insets.xs + 1),
                        Expanded(
                          child: Text(
                            'Read on this phone. Never uploaded.',
                            style: context.texts.labelSmall?.copyWith(color: muted),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            secondChild: const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

/// Shown where a [SourceSmsCard] would be, when there is no message to show.
///
/// Bodies are purged by the retention job and a manually entered transaction
/// never had one. Both are normal, so this says which it is instead of
/// rendering an error.
class SourceSmsUnavailable extends StatelessWidget {
  const SourceSmsUnavailable({required this.reason, super.key});

  const SourceSmsUnavailable.purged({super.key})
      : reason = 'The original message was removed by the privacy cleanup. '
            'The transaction it produced is unaffected.';

  const SourceSmsUnavailable.manual({super.key})
      : reason = 'You added this by hand, so there is no message behind it.';

  final String reason;

  @override
  Widget build(BuildContext context) {
    final Color muted = context.colors.onSurfaceVariant;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerHighest,
        borderRadius: Radii.cardBorder,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.inventory_2_outlined, size: 16, color: muted),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Text(
              reason,
              style: context.texts.bodySmall?.copyWith(color: muted),
            ),
          ),
        ],
      ),
    );
  }
}
