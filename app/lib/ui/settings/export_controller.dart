/// Getting the user's data out of the app, and wiping it.
///
/// This is the other half of "100% on-device". Data that only lives on one
/// phone is data one cracked screen away from being gone, so the app must be
/// able to hand it back in a format the user actually owns - a CSV any
/// spreadsheet opens - and it must be able to delete everything on request,
/// for real.
///
/// The export is written to a folder on the device. Nothing is uploaded, and
/// no share sheet is involved, because handing the file to another app is the
/// user's decision to make from their file manager, not the app's to make for
/// them.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ledger/contracts/contracts.dart';
import 'package:ledger/core/result.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/ui/theme/theme.dart';
import 'package:path_provider/path_provider.dart';

/// How many transactions one export will read.
///
/// Generous, and still bounded: an export is not a reason to load an unbounded
/// table into memory on a phone.
const int kExportRowLimit = 20000;

/// Where an export ended up, so the screen can tell the user exactly where to
/// look for it.
@immutable
class ExportReceipt {
  const ExportReceipt({
    required this.path,
    required this.rowCount,
    required this.bytes,
  });

  final String path;
  final int rowCount;
  final int bytes;
}

final NotifierProvider<ExportController, bool> exportControllerProvider =
    NotifierProvider<ExportController, bool>(ExportController.new);

class ExportController extends Notifier<bool> {
  @override
  bool build() => false;

  LedgerRepository get _repo => ref.read(ledgerRepositoryProvider);

  /// Writes every transaction to a CSV file on this device.
  ///
  /// Message text is deliberately NOT exported. The bodies are the most
  /// sensitive thing the app holds, they are not needed to reconstruct a
  /// ledger, and a file sitting in a shared folder is exactly the place they
  /// should not be.
  Future<Result<ExportReceipt>> exportCsv() async {
    if (state) {
      return Err<ExportReceipt>(AppError.conflict('An export is already running.'));
    }
    state = true;
    try {
      final Result<List<Transaction>> read = await _repo.transactions(
        const TxnQuery(
          limit: kExportRowLimit,
          includeExcluded: true,
          newestFirst: false,
        ),
      );
      final AppError? readError = read.errorOrNull;
      if (readError != null) return Err<ExportReceipt>(readError);
      final List<Transaction> rows = read.getOrElse(const <Transaction>[]);

      final Result<Directory> dir = await _exportDirectory();
      final AppError? dirError = dir.errorOrNull;
      if (dirError != null) return Err<ExportReceipt>(dirError);
      final Directory directory = dir.getOrElse(Directory.systemTemp);

      final DateTime now = ref.read(clockProvider)();
      final String name = 'ledger-${_stamp(now)}.csv';
      final String csv = buildCsv(rows);

      return await Result.guardAsync<ExportReceipt>(
        () async {
          final File file =
              File('${directory.path}${Platform.pathSeparator}$name');
          await file.parent.create(recursive: true);
          // UTF-8 with a BOM: without it, Excel on Windows mangles the rupee
          // symbol and every Devanagari merchant name in the file.
          await file.writeAsString('﻿$csv', flush: true);
          return ExportReceipt(
            path: file.path,
            rowCount: rows.length,
            bytes: utf8.encode(csv).length,
          );
        },
        code: ErrorCodes.io,
        message: 'The export file could not be written.',
      );
    } finally {
      state = false;
    }
  }

  /// Deletes every row in the local database. Irreversible by design.
  Future<Result<void>> wipeEverything() async {
    state = true;
    try {
      return await _repo.wipe();
    } finally {
      state = false;
    }
  }

  /// Deletes stored message text older than [age], keeping the transactions
  /// that were read out of it.
  ///
  /// The retention control. Message bodies are the most sensitive thing the
  /// app holds and the app only needs them to re-parse after a rules update;
  /// once the user is happy with what was read, they are free to go. Returns
  /// how many were purged.
  Future<Result<int>> purgeMessageText(Duration age) async {
    state = true;
    try {
      final DateTime cutoff = ref.read(clockProvider)().subtract(age);
      return await _repo.purgeMessageBodies(olderThan: cutoff);
    } finally {
      state = false;
    }
  }

  /// The app's own folder in shared storage when there is one, because a file
  /// the user cannot reach from a file manager is not really an export.
  /// Falls back to the private documents directory.
  Future<Result<Directory>> _exportDirectory() async {
    return Result.guardAsync<Directory>(
      () async {
        if (Platform.isAndroid) {
          final Directory? external = await getExternalStorageDirectory();
          if (external != null) {
            return Directory(
                '${external.path}${Platform.pathSeparator}exports');
          }
        }
        final Directory docs = await getApplicationDocumentsDirectory();
        return Directory('${docs.path}${Platform.pathSeparator}exports');
      },
      code: ErrorCodes.io,
      message: 'No writable folder was available for the export.',
    );
  }

  static String _stamp(DateTime now) {
    final DateTime local = now.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}${two(local.month)}${two(local.day)}'
        '-${two(local.hour)}${two(local.minute)}';
  }
}

/// The CSV text for [rows].
///
/// Pure, so the format is testable without touching a filesystem.
///
/// Amounts are written as plain rupee decimals derived from integer paise -
/// never from a `double`, so the column a spreadsheet sums matches the total
/// the app shows. The sign column is separate from the amount, because a
/// spreadsheet user wants to filter on direction, not parse a minus.
String buildCsv(List<Transaction> rows) {
  final StringBuffer out = StringBuffer();
  out.writeln(const <String>[
    'date',
    'time',
    'amount',
    'currency',
    'direction',
    'category',
    'kind',
    'counts_as_spend',
    'merchant',
    'channel',
    'account',
    'card',
    'reference',
    'note',
    'status',
    'excluded_from_totals',
    'source',
    'category_source',
    'confidence',
    'transaction_id',
  ].map(_csvCell).join(','));

  for (final Transaction txn in rows) {
    final DateTime local = txn.occurredAt.toLocal();
    out.writeln(<String>[
      txn.bookingDate,
      '${_two(local.hour)}:${_two(local.minute)}',
      rupeeString(txn.amount),
      txn.amount.currency,
      txn.direction.wire,
      txn.categoryPath,
      txn.kind.wire,
      txn.countsAsSpend ? 'yes' : 'no',
      txn.merchantName ?? txn.merchantRaw ?? '',
      txn.channel.wire,
      txn.accountTail ?? '',
      txn.cardTail ?? '',
      txn.ref ?? '',
      txn.note ?? '',
      txn.status.wire,
      txn.isExcludedFromTotals ? 'yes' : 'no',
      txn.source.wire,
      txn.categorySource.wire,
      txn.confidence.toStringAsFixed(2),
      txn.id,
    ].map(_csvCell).join(','));
  }
  return out.toString();
}

/// `1245.50` from `Money(124550)`. Integer arithmetic only.
String rupeeString(Money amount) {
  final int paise = amount.paise;
  final String sign = paise < 0 ? '-' : '';
  final int magnitude = paise.abs();
  return '$sign${magnitude ~/ 100}.${_two(magnitude.remainder(100))}';
}

String _two(int value) => value.toString().padLeft(2, '0');

/// RFC 4180 quoting. Every cell is quoted, which is legal and removes every
/// question about commas, quotes and newlines in a merchant name.
String _csvCell(String raw) {
  final String flattened = raw.replaceAll('\r\n', ' ').replaceAll('\n', ' ');
  return '"${flattened.replaceAll('"', '""')}"';
}
