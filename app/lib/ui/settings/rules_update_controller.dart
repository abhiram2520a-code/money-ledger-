/// The rules pack: which one is in force, and the entirely optional business
/// of fetching a newer one.
///
/// This is the only place in the app that touches the network, and the whole
/// design of this file is that it does not matter. The pack is compiled into
/// the APK, so parsing, categorising and reporting all work on a device that
/// never has a connection - for good. A failed check is reported as a fact
/// ("you are offline"), never as an error state, and a downloaded pack that
/// does not validate is discarded with the current rules left untouched.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ledger/contracts/contracts.dart';
import 'package:ledger/core/result.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/ui/theme/theme.dart';

/// What the update panel is showing right now.
@immutable
class RulesUpdateState {
  const RulesUpdateState({
    this.busy = false,
    this.message,
    this.available,
    this.isOffline = false,
    this.isFailure = false,
  });

  final bool busy;

  /// One sentence for the user. `null` before anything has been tried.
  final String? message;

  /// A validated, strictly newer pack waiting to be applied.
  final RuleSet? available;

  /// The check could not reach the server. Routine, not an error.
  final bool isOffline;

  /// The check reached the server and something was actually wrong.
  final bool isFailure;

  RulesUpdateState copyWith({
    bool? busy,
    String? message,
    RuleSet? available,
    bool? isOffline,
    bool? isFailure,
    bool clearAvailable = false,
  }) {
    return RulesUpdateState(
      busy: busy ?? this.busy,
      message: message ?? this.message,
      available: clearAvailable ? null : (available ?? this.available),
      isOffline: isOffline ?? this.isOffline,
      isFailure: isFailure ?? this.isFailure,
    );
  }
}

final NotifierProvider<RulesUpdateController, RulesUpdateState>
    rulesUpdateControllerProvider =
    NotifierProvider<RulesUpdateController, RulesUpdateState>(
        RulesUpdateController.new);

class RulesUpdateController extends Notifier<RulesUpdateState> {
  @override
  RulesUpdateState build() => const RulesUpdateState();

  RulesProvider get _rules => ref.read(rulesSourceProvider);

  /// Asks the config server whether a newer pack exists.
  ///
  /// Never leaves the user on a spinner and never raises an alarm. Offline is
  /// a sentence, not a red banner, because the app is designed to be used that
  /// way indefinitely.
  Future<void> check() async {
    if (state.busy) return;
    state = const RulesUpdateState(busy: true, message: 'Checking...');
    final Result<RuleSet?> result = await _rules.checkForUpdate();

    switch (result) {
      case Ok<RuleSet?>(value: final RuleSet? pack):
        if (pack == null) {
          state = RulesUpdateState(
            message: 'You already have the newest rules '
                '(version ${_rules.version}).',
          );
        } else {
          state = RulesUpdateState(
            message: 'Version ${pack.version} is available. '
                'Your own rules are never touched by an update.',
            available: pack,
          );
        }
      case Err<RuleSet?>(error: final AppError error):
        state = _stateForError(error);
    }
  }

  /// Adopts a pack that has already been fetched and validated.
  Future<void> applyAvailable() async {
    final RuleSet? pack = state.available;
    if (pack == null || state.busy) return;
    state = state.copyWith(busy: true, message: 'Applying...');
    final Result<void> applied = await _rules.applyUpdate(pack);
    final AppError? error = applied.errorOrNull;
    state = error == null
        ? RulesUpdateState(message: 'Updated to version ${pack.version}.')
        : RulesUpdateState(
            message: 'That update was rejected, so your current rules are '
                'still in force. (${error.message})',
            isFailure: true,
          );
  }

  /// Throws away any downloaded pack and goes back to the one inside the app.
  ///
  /// The recovery path: whatever a server ever sent, the bundled pack is
  /// always there and always works.
  Future<void> resetToBundled() async {
    if (state.busy) return;
    state = state.copyWith(busy: true, message: 'Restoring...');
    final Result<RuleSet> result = await _rules.resetToBundled();
    state = result.fold(
      (RuleSet pack) => RulesUpdateState(
        message: 'Restored the rules built into the app '
            '(version ${pack.version}).',
      ),
      (AppError error) => RulesUpdateState(
        message: 'Could not restore the built-in rules: ${error.message}',
        isFailure: true,
      ),
    );
  }

  static RulesUpdateState _stateForError(AppError error) {
    if (error.isOffline || error.code == ErrorCodes.network) {
      return const RulesUpdateState(
        message: 'No connection, so there was nothing to check. The app does '
            'not need one - everything works from the rules inside it.',
        isOffline: true,
      );
    }
    return switch (error.code) {
      ErrorCodes.timeout => const RulesUpdateState(
          message: 'The update server did not answer in time. Nothing changed.',
          isOffline: true,
        ),
      ErrorCodes.corruptRules => const RulesUpdateState(
          message: 'The server sent a rules pack that did not pass the checks, '
              'so it was thrown away. Your current rules are untouched.',
          isFailure: true,
        ),
      _ => RulesUpdateState(
          message: 'The check did not complete: ${error.message}',
          isFailure: true,
        ),
    };
  }
}
