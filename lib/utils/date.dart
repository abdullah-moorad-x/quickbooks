import 'package:intl/intl.dart';
import '../core/constants.dart';

final DateFormat dfDay = DateFormat(kDatePattern);
final DateFormat dfMonth = DateFormat('yyyy-MM');

String formatInvoiceDate(DateTime d) => dfDay.format(d);

DateTime parseInvoiceDate(String s) {
  try { return dfDay.parseStrict(s); } catch (_) {}
  try { return DateFormat('yyyy-MM-dd').parseStrict(s); } catch (_) {}
  final t = DateTime.tryParse(s);
  if (t != null) return t;
  throw FormatException('Invalid date format: $s');
}

