import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/ui/theme/theme.dart';

/// About.
///
/// Says what the app is for and, just as usefully, what it is not: not a
/// budgeting coach, not a bank connection, not an advisor. An expense tracker
/// that oversells itself gets judged against a promise it never made.
class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  static const String routeName = '/settings/about';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final RuleSet? rules = ref.watch(ruleSetProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ContentWidth(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
              Insets.xl, Insets.xxl, Insets.xl, Insets.huge),
          children: <Widget>[
            Icon(Icons.account_balance_wallet_outlined,
                size: 48, color: context.colors.primary),
            const SizedBox(height: Insets.lg),
            Text(
              'Money Ledger',
              style: context.texts.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: Insets.xs),
            Text(
              'An expense ledger built from the bank and UPI messages already '
              'on this phone.',
              style: context.texts.bodyMedium
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
            const SizedBox(height: Insets.xxl),

            const _Point(
              title: 'It reads, it does not guess',
              body: 'Every transaction comes from a message the app can show '
                  'you. When it does not recognise a payee it puts the '
                  'transaction in Review and asks, instead of filing it '
                  'somewhere plausible.',
            ),
            const _Point(
              title: 'Transfers are not spending',
              body: 'Moving money between your own accounts, paying a credit '
                  'card bill, withdrawing cash and buying an investment are '
                  'all tracked, and none of them are added to your spend. '
                  'Counting them is the reason most Indian expense trackers '
                  'show a number their users do not believe.',
            ),
            const _Point(
              title: 'It is not a budgeting coach',
              body: 'The app reports what happened. It does not set targets '
                  'for you, does not score your habits, and gives no '
                  'investment or financial advice.',
            ),
            const _Point(
              title: 'It is not connected to your bank',
              body: 'There is no bank login and no account aggregator. If a '
                  'bank stops sending a message, the app stops seeing that '
                  'transaction - which is why the totals are worth checking '
                  'against a statement now and then.',
            ),

            const SizedBox(height: Insets.lg),
            const Divider(),
            const SizedBox(height: Insets.lg),
            Text(
              rules == null || rules.isEmpty
                  ? 'Reading rules: loading'
                  : 'Reading rules: version ${rules.version}, '
                      '${rules.merchants.length} known merchants',
              style: context.texts.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
            const SizedBox(height: Insets.xs),
            Text(
              'Works fully offline. No account, no analytics, no data leaves '
              'this phone.',
              style: context.texts.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _Point extends StatelessWidget {
  const _Point({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title,
              style: context.texts.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Insets.xxs),
          Text(body,
              style: context.texts.bodyMedium?.copyWith(
                height: 1.45,
                color: context.colors.onSurfaceVariant,
              )),
        ],
      ),
    );
  }
}
