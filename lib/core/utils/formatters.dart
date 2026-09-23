import 'package:intl/intl.dart';

/// Human-friendly formatting helpers.
abstract final class Format {
  static const List<String> _units = ['B', 'KB', 'MB', 'GB', 'TB'];

  /// `0 B`, `12 KB`, `3.4 MB`, `1.25 GB`.
  static String bytes(int? bytes) {
    if (bytes == null) return '—';
    if (bytes < 1024) return '$bytes B';
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < _units.length - 1) {
      value /= 1024;
      unit++;
    }
    final digits = value >= 100 ? 0 : (value >= 10 ? 1 : 2);
    return '${value.toStringAsFixed(digits)} ${_units[unit]}';
  }

  /// `1 file`, `3 files`, `1,204 files`.
  static String count(int count, String singular, [String? plural]) {
    final number = NumberFormat.decimalPattern().format(count);
    return '$number ${count == 1 ? singular : plural ?? '${singular}s'}';
  }

  /// `just now`, `5 min ago`, `Yesterday`, `12 Sep 2026`.
  static String relative(DateTime time, {DateTime? now}) {
    final reference = now ?? DateTime.now();
    final difference = reference.difference(time);
    if (difference.inSeconds < 60) return 'just now';
    if (difference.inMinutes < 60) return '${difference.inMinutes} min ago';
    final today = DateTime(reference.year, reference.month, reference.day);
    final day = DateTime(time.year, time.month, time.day);
    final days = today.difference(day).inDays;
    if (days == 0) return 'Today, ${DateFormat.Hm().format(time)}';
    if (days == 1) return 'Yesterday';
    if (days < 7) return '$days days ago';
    return DateFormat.yMMMd().format(time);
  }

  /// Shortens long paths in the middle: `C:\Users\…\Photos\2024`.
  static String middleEllipsis(String text, int maxLength) {
    if (text.length <= maxLength) return text;
    final keep = maxLength - 1;
    final head = (keep / 2).ceil();
    final tail = keep - head;
    return '${text.substring(0, head)}…${text.substring(text.length - tail)}';
  }
}
