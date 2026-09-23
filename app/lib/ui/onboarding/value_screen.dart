import 'package:flutter/material.dart';
import 'package:ledger/ui/theme/theme.dart';

/// Screen 1. What the app is, in three lines, before it asks for anything.
///
/// No permission is requested here and no data is read here. This screen exists
/// so that the disclosure screen that follows is answering a question the user
/// already has, rather than ambushing them on launch.
class ValueScreen extends StatelessWidget {
  const ValueScreen({required this.onContinue, super.key});

  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = context.colors;
    return ContentWidth(
      child: Column(
        children: <Widget>[
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                Insets.xxl,
                Insets.huge,
                Insets.xxl,
                Insets.xxl,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: Radii.cardBorder,
                    ),
                    child: Icon(
                      Icons.account_balance_wallet_outlined,
                      color: colors.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: Insets.xxl),
                  Text(
                    'Your spending,\nwithout the data entry',
                    style: context.texts.headlineMedium,
                  ),
                  const SizedBox(height: Insets.md),
                  Text(
                    'Your bank already texts you every time money moves. '
                    'This app turns those messages into a ledger, on this phone.',
                    style: context.texts.bodyLarge?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: Insets.xxxl),
                  const _ValuePoint(
                    icon: Icons.bolt_outlined,
                    title: 'Nothing to type',
                    body: 'Every UPI payment, card swipe and auto-debit lands in '
                        'the ledger by itself, with the merchant and the category '
                        'already filled in.',
                  ),
                  const SizedBox(height: Insets.xl),
                  const _ValuePoint(
                    icon: Icons.phone_android_outlined,
                    title: 'Stays on this phone',
                    body: 'No account, no sign-in, no server. Your messages are read '
                        'and your ledger is stored here, and nowhere else.',
                  ),
                  const SizedBox(height: Insets.xl),
                  const _ValuePoint(
                    icon: Icons.visibility_outlined,
                    title: 'Shows its working',
                    body: 'Every transaction can show you the exact message it came '
                        'from and why it was filed where it was. When it gets one '
                        'wrong, one tap fixes it for good.',
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.xxl,
              0,
              Insets.xxl,
              Insets.xxl,
            ),
            child: Column(
              children: <Widget>[
                FilledButton(
                  onPressed: onContinue,
                  child: const Text('Get started'),
                ),
                const SizedBox(height: Insets.md),
                Text(
                  'Next: exactly what this app reads, and what it does not.',
                  style: context.texts.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ValuePoint extends StatelessWidget {
  const _ValuePoint({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, color: context.colors.primary, size: 22),
        const SizedBox(width: Insets.lg),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: context.texts.titleMedium),
              const SizedBox(height: Insets.xxs),
              Text(
                body,
                style: context.texts.bodyMedium?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
