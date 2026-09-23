import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_palette.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/feedback.dart';
import '../../auth/application/app_locker.dart';

/// Locks the app, and says which items could not be locked along with it.
Future<void> lockAppWithFeedback(WidgetRef ref) async {
  final left = await ref.read(appLockerProvider).lockApp();
  if (left.isEmpty) return;
  showToast(
    '${Format.count(left.length, 'item')} stayed unlocked: they need their '
    'own password, or a file in them is open.',
    tone: Tone.warning,
  );
}
