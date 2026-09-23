import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ledger/ui/categories/categories.dart';
import 'package:ledger/ui/settings/settings.dart';
import 'package:ledger/ui/theme/theme.dart';
import 'package:ledger/ui/transactions/transactions_screen.dart';
import 'package:ledger/ui/uncategorized/uncategorized.dart';

import 'dashboard_screen.dart';

/// The places the app has. No drawer, no nested navigator, no half-finished
/// sections: a month view, the ledger behind it, the queue of things the app
/// refused to guess, the category browser, and the settings that prove the
/// privacy claim.
enum HomeTab { month, transactions, review, categories, settings }

/// Which tab is showing.
///
/// A provider rather than local state because the dashboard hands off to
/// another tab with state already set ("show me this month's Food & Dining",
/// "review the 38 unknowns"), and that hand-off should not need a route push
/// the user then has to back out of.
final StateProvider<HomeTab> homeTabProvider =
    StateProvider<HomeTab>((Ref ref) => HomeTab.month);

/// The post-onboarding shell.
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final HomeTab tab = ref.watch(homeTabProvider);
    final int uncategorized = ref.watch(uncategorizedCountProvider).valueOrNull ?? 0;

    return Scaffold(
      // IndexedStack, not a PageView: switching tabs must not throw away the
      // transaction list's scroll position or re-run its queries.
      body: IndexedStack(
        index: tab.index,
        children: const <Widget>[
          DashboardScreen(),
          TransactionsScreen(),
          UncategorizedScreen(),
          CategoriesScreen(),
          SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab.index,
        onDestinationSelected: (int index) =>
            ref.read(homeTabProvider.notifier).state = HomeTab.values[index],
        destinations: <Widget>[
          const NavigationDestination(
            icon: Icon(Icons.pie_chart_outline),
            selectedIcon: Icon(Icons.pie_chart),
            label: 'Month',
          ),
          const NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long),
            label: 'Ledger',
          ),
          NavigationDestination(
            // The badge is the app admitting what it does not know. It is meant
            // to be visible, not tucked away.
            icon: Badge(
              isLabelVisible: uncategorized > 0,
              label: Text('$uncategorized'),
              child: const Icon(Icons.help_outline),
            ),
            selectedIcon: const Icon(Icons.help),
            label: 'Review',
          ),
          const NavigationDestination(
            icon: Icon(Icons.category_outlined),
            selectedIcon: Icon(Icons.category),
            label: 'Categories',
          ),
          const NavigationDestination(
            icon: Icon(Icons.shield_outlined),
            selectedIcon: Icon(Icons.shield),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
