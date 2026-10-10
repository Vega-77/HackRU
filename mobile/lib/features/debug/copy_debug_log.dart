import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/logging/debug_log.dart';

/// Copies the whole debug log to the clipboard and says how much went.
///
/// Shared by the experiment screen and Settings so both copy the same text.
Future<void> copyDebugLog(BuildContext context) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final text = log.dump();
  try {
    await Clipboard.setData(ClipboardData(text: text));
  } catch (error, stack) {
    log.e('Copying the debug log failed', error, stack);
    messenger?.showSnackBar(
      const SnackBar(content: Text("Couldn't copy the log. Try again.")),
    );
    return;
  }
  final lines = '\n'.allMatches(text).length;
  log.i('Debug log copied: $lines lines');
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text('Copied ${groupDigits(lines)} log lines')),
    );
}

/// 4812 becomes `4,812`.
String groupDigits(int n) =>
    n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
