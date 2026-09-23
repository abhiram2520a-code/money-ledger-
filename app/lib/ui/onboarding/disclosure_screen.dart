import 'package:flutter/material.dart';
import 'package:ledger/ui/theme/theme.dart';

/// Screen 2. The prominent disclosure.
///
/// This screen is a compliance artefact as much as a design one. Google Play's
/// User Data policy requires that, before any runtime request for SMS access,
/// the app shows an in-app disclosure that:
///
/// * lives inside the app, not only in the listing or a website;
/// * appears in normal use and does not require digging into a menu;
/// * describes the data accessed and explains how it is used and shared;
/// * is not merely a link to a privacy policy;
/// * immediately precedes the runtime permission request; and
/// * is accepted by an affirmative action - never by navigating away,
///   never by an auto-dismissing message.
///
/// Hence: full-screen, no timer, no auto-advance, [PopScope] with `canPop:
/// false` so the back gesture cannot be mistaken for consent, and two explicit
/// buttons where declining is a first-class outcome rather than a grey link.
///
/// The copy below is deliberately concrete. "We respect your privacy" tells a
/// reviewer nothing; "nothing leaves this phone, and here is the one network
/// request the app ever makes" is a claim that can be checked.
class DisclosureScreen extends StatelessWidget {
  const DisclosureScreen({
    required this.onAccept,
    required this.onDecline,
    super.key,
    this.busy = false,
  });

  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = context.colors;
    return PopScope(
      // Navigating away is not consent, so there is nowhere to navigate to.
      canPop: false,
      child: ContentWidth(
        child: Column(
          children: <Widget>[
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  Insets.xxl,
                  Insets.xxxl,
                  Insets.xxl,
                  Insets.xl,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(Icons.sms_outlined, color: colors.primary, size: 28),
                    const SizedBox(height: Insets.lg),
                    Text(
                      'Before we ask for permission',
                      style: context.texts.headlineSmall,
                    ),
                    const SizedBox(height: Insets.sm),
                    Text(
                      'The next screen is Android asking whether this app may read '
                      'the SMS messages on this phone. Here is exactly what that '
                      'permission is used for.',
                      style: context.texts.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: Insets.xxl),
                    const _DisclosureBlock(
                      icon: Icons.search,
                      title: 'What is read',
                      body: 'The SMS messages already stored on this phone, and new '
                          'ones as they arrive. The app looks at each message only '
                          'to decide whether it is a bank, card or UPI alert saying '
                          'money moved.',
                    ),
                    const _DisclosureBlock(
                      icon: Icons.calculate_outlined,
                      title: 'What it is used for',
                      body: 'Bank alerts are broken down on this phone into a date, '
                          'an amount, an account and a merchant, and saved as '
                          'transactions in a ledger stored on this phone. That is '
                          'the entire purpose of the permission.',
                    ),
                    const _DisclosureBlock(
                      icon: Icons.block_outlined,
                      title: 'What is ignored',
                      body: 'Personal messages, OTPs and promotional SMS are not '
                          'turned into transactions and are never shown anywhere in '
                          'the app. The app has no inbox, no search across your '
                          'messages and no contact access.',
                    ),
                    const _DisclosureBlock(
                      icon: Icons.cloud_off_outlined,
                      title: 'What is shared or uploaded',
                      body: 'Nothing. No message text, no amounts, no merchant '
                          'names, no phone number, no advertising ID. There is no '
                          'account to create and no server holding your ledger. '
                          'Nothing is shared with any other company, and nothing is '
                          'used for advertising, credit scoring or lending.',
                    ),
                    const _DisclosureBlock(
                      icon: Icons.wifi_off_outlined,
                      title: 'The one time it uses the internet',
                      body: 'To download an updated list of bank message formats, so '
                          'parsing keeps working when a bank changes its wording. '
                          'That request sends nothing about you, and the app works '
                          'completely offline without it.',
                    ),
                    const _DisclosureBlock(
                      icon: Icons.delete_outline,
                      title: 'You stay in control',
                      body: 'You can turn SMS reading off, delete everything the app '
                          'has stored, and see the exact list of messages it read, '
                          'at any time in Settings.',
                      last: true,
                    ),
                    const SizedBox(height: Insets.xl),
                    Container(
                      padding: Pads.cardTight,
                      decoration: BoxDecoration(
                        color: colors.surfaceContainerHigh,
                        borderRadius: Radii.cardBorder,
                      ),
                      child: Text(
                        'If you say no, the app still works. You can add '
                        'transactions yourself and turn this on later. Nothing is '
                        'locked behind the permission.',
                        style: context.texts.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.xxl,
                Insets.sm,
                Insets.xxl,
                Insets.xxl,
              ),
              child: Column(
                children: <Widget>[
                  FilledButton(
                    onPressed: busy ? null : onAccept,
                    child: busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('I understand, allow SMS access'),
                  ),
                  const SizedBox(height: Insets.sm),
                  TextButton(
                    onPressed: busy ? null : onDecline,
                    child: const Text('No thanks, I will add them myself'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DisclosureBlock extends StatelessWidget {
  const _DisclosureBlock({
    required this.icon,
    required this.title,
    required this.body,
    this.last = false,
  });

  final IconData icon;
  final String title;
  final String body;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : Insets.xl),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 20, color: context.colors.onSurfaceVariant),
          const SizedBox(width: Insets.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: context.texts.titleSmall),
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
      ),
    );
  }
}
