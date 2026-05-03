import 'dart:io';

import '../utils/date.dart';

class SlipOcrResult {
  final String rawText;
  final DateTime? date;
  final double? amount;
  final String? receiver;

  const SlipOcrResult({
    required this.rawText,
    required this.date,
    required this.amount,
    required this.receiver,
  });
}

class SlipOcrService {
  static Future<SlipOcrResult> readFromClipboardImage() async {
    if (!Platform.isWindows) {
      throw Exception('Slip OCR is currently available on Windows desktop only.');
    }

    final workDir = await Directory.systemTemp.createTemp('quickbill_ocr_');
    final imagePath = '${workDir.path}${Platform.pathSeparator}slip.png';

    final escapedPath = imagePath.replaceAll("'", "''");
    final saveImage = await Process.run(
      'powershell',
      [
        '-NoProfile',
        '-Command',
        "Add-Type -AssemblyName System.Windows.Forms; "
            "Add-Type -AssemblyName System.Drawing; "
            "\$img = Get-Clipboard -Format Image; "
            "if (\$null -eq \$img) { Write-Error 'No image in clipboard'; exit 2 }; "
            "\$img.Save('$escapedPath', [System.Drawing.Imaging.ImageFormat]::Png);",
      ],
    );
    if (saveImage.exitCode != 0) {
      throw Exception('No image found in clipboard. Copy a slip screenshot first.');
    }

    String raw = await _ocrWithTesseract(imagePath);
    if (raw.isEmpty) {
      raw = await _ocrWithWindowsApi(imagePath);
    }
    if (raw.isEmpty) {
      throw Exception(
        'OCR could not read text from the slip image. '
        'Install Tesseract OCR (or add it to PATH), then try a clearer slip screenshot.',
      );
    }

    return SlipOcrResult(
      rawText: raw,
      date: _extractDate(raw),
      amount: _extractAmount(raw),
      receiver: _extractReceiver(raw),
    );
  }

  static Future<String> _ocrWithTesseract(String imagePath) async {
    final candidates = await _resolveTesseractExecutables();

    for (final exe in candidates) {
      try {
        for (final psm in const ['6', '11']) {
          final ocr = await Process.run(exe, [imagePath, 'stdout', '--psm', psm, '-l', 'eng']);
          if (ocr.exitCode != 0) continue;
          final text = (ocr.stdout ?? '').toString().trim();
          if (text.isNotEmpty) return text;
        }
      } on ProcessException {
        continue;
      }
    }
    return '';
  }

  static Future<List<String>> _resolveTesseractExecutables() async {
    final candidates = <String>['tesseract'];

    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    final programData = Platform.environment['ProgramData'] ?? '';
    final userProfile = Platform.environment['USERPROFILE'] ?? '';

    final explicitPaths = <String>[
      r'C:\Program Files\Tesseract-OCR\tesseract.exe',
      r'C:\Program Files (x86)\Tesseract-OCR\tesseract.exe',
      if (localAppData.isNotEmpty) '$localAppData\\Programs\\Tesseract-OCR\\tesseract.exe',
      if (programData.isNotEmpty) '$programData\\chocolatey\\bin\\tesseract.exe',
      if (userProfile.isNotEmpty) '$userProfile\\scoop\\apps\\tesseract\\current\\tesseract.exe',
    ];

    for (final path in explicitPaths) {
      if (await File(path).exists()) {
        candidates.add(path);
      }
    }

    try {
      final whereRun = await Process.run('where.exe', ['tesseract']);
      if (whereRun.exitCode == 0) {
        final lines = (whereRun.stdout ?? '')
            .toString()
            .split(RegExp(r'[\r\n]+'))
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty);
        candidates.addAll(lines);
      }
    } on ProcessException {
      // Keep current candidates.
    }

    final deduped = <String>[];
    final seen = <String>{};
    for (final c in candidates) {
      final key = c.toLowerCase();
      if (seen.add(key)) deduped.add(c);
    }
    return deduped;
  }

  static Future<String> _ocrWithWindowsApi(String imagePath) async {
    final escapedPath = imagePath.replaceAll("'", "''");
    const command = r"$ErrorActionPreference = 'Stop'; "
        r"Add-Type -AssemblyName System.Runtime.WindowsRuntime; "
        r"$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType=WindowsRuntime]; "
        r"$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType=WindowsRuntime]; "
        r"$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType=WindowsRuntime]; "
        r"$null = [Windows.Globalization.Language, Windows, ContentType=WindowsRuntime]; "
        r"$asTaskDef = [System.WindowsRuntimeSystemExtensions].GetMethods() | "
        r"  Where-Object { $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 } | "
        r"  Select-Object -First 1; "
        r"function AwaitOp($op, [Type]$t) { "
        r"  $m = $asTaskDef.MakeGenericMethod($t); "
        r"  $task = $m.Invoke($null, @($op)); "
        r"  $task.Wait(); "
        r"  $task.Result "
        r"} "
        r"$f = AwaitOp ([Windows.Storage.StorageFile]::GetFileFromPathAsync('__PATH__')) ([Windows.Storage.StorageFile]); "
        r"$s = AwaitOp ($f.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream]); "
        r"$d = AwaitOp ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($s)) ([Windows.Graphics.Imaging.BitmapDecoder]); "
        r"$b = AwaitOp ($d.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap]); "
        r"$e = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages(); "
        r"if ($null -eq $e) { "
        r"  $lang = New-Object Windows.Globalization.Language('en-US'); "
        r"  $e = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang); "
        r"} "
        r"if ($null -eq $e) { Write-Error 'No OCR language available'; exit 3 } "
        r"$r = AwaitOp ($e.RecognizeAsync($b)) ([Windows.Media.Ocr.OcrResult]); "
        r"$r.Text";

    final run = await Process.run(
      'powershell',
      ['-NoProfile', '-Command', command.replaceAll('__PATH__', escapedPath)],
    );
    if (run.exitCode != 0) {
      return '';
    }
    return (run.stdout ?? '').toString().trim();
  }

  static DateTime? _extractDate(String text) {
    final lines = text.split(RegExp(r'[\r\n]+')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

    final numericDate = RegExp(r'\b(\d{1,4}[\/\-.]\d{1,2}[\/\-.]\d{1,4})\b');
    for (final line in lines) {
      final m = numericDate.firstMatch(line);
      if (m == null) continue;
      final v = m.group(1);
      if (v == null) continue;
      final parsed = _parseFlexibleNumericDate(v);
      if (parsed != null) return parsed;
      try {
        return parseInvoiceDate(v.replaceAll('.', '-').replaceAll('/', '-'));
      } catch (_) {}
    }

    final monthNameDate = RegExp(
      r'\b(\d{1,2}\s+[A-Za-z]{3,9}\s+\d{2,4}|[A-Za-z]{3,9}\s+\d{1,2},?\s+\d{2,4})\b',
      caseSensitive: false,
    );
    for (final line in lines) {
      final m = monthNameDate.firstMatch(line);
      if (m == null) continue;
      final v = m.group(1);
      if (v == null) continue;
      try {
        return DateTime.parse(_normalizeMonthDate(v));
      } catch (_) {}
    }
    return null;
  }

  static DateTime? _parseFlexibleNumericDate(String input) {
    final raw = input.trim().replaceAll('.', '-').replaceAll('/', '-');
    final parts = raw.split('-');
    if (parts.length != 3) return null;

    int? a = int.tryParse(parts[0]);
    int? b = int.tryParse(parts[1]);
    int? c = int.tryParse(parts[2]);
    if (a == null || b == null || c == null) return null;

    int year;
    int month;
    int day;

    if (parts[0].length == 4) {
      year = a;
      month = b;
      day = c;
    } else if (parts[2].length == 4 || parts[2].length == 2) {
      year = c;
      if (year < 100) year += 2000;
      if (a > 12 && b <= 12) {
        day = a;
        month = b;
      } else if (b > 12 && a <= 12) {
        month = a;
        day = b;
      } else {
        day = a;
        month = b;
      }
    } else {
      return null;
    }

    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    try {
      final d = DateTime(year, month, day);
      if (d.year == year && d.month == month && d.day == day) return d;
    } catch (_) {}
    return null;
  }

  static String _normalizeMonthDate(String input) {
    final s = input.trim().replaceAll(',', '');
    final p = s.split(RegExp(r'\s+'));
    if (p.length != 3) return s;

    int day;
    String month;
    int year;
    if (RegExp(r'^\d+$').hasMatch(p[0])) {
      day = int.tryParse(p[0]) ?? 1;
      month = p[1];
      year = int.tryParse(p[2]) ?? DateTime.now().year;
    } else {
      month = p[0];
      day = int.tryParse(p[1]) ?? 1;
      year = int.tryParse(p[2]) ?? DateTime.now().year;
    }
    if (year < 100) year += 2000;
    final mon = _monthNumber(month);
    return '${year.toString().padLeft(4, '0')}-${mon.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
  }

  static int _monthNumber(String month) {
    final m = month.toLowerCase();
    if (m.startsWith('jan')) return 1;
    if (m.startsWith('feb')) return 2;
    if (m.startsWith('mar')) return 3;
    if (m.startsWith('apr')) return 4;
    if (m.startsWith('may')) return 5;
    if (m.startsWith('jun')) return 6;
    if (m.startsWith('jul')) return 7;
    if (m.startsWith('aug')) return 8;
    if (m.startsWith('sep')) return 9;
    if (m.startsWith('oct')) return 10;
    if (m.startsWith('nov')) return 11;
    if (m.startsWith('dec')) return 12;
    return 1;
  }

  static double? _extractAmount(String text) {
    final normalized = text.replaceAll('\n', ' ');
    final tagged = RegExp(
      r'(?:rs\.?|inr|amount|paid|payment)\s*[:\-]?\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)',
      caseSensitive: false,
    );
    final t = tagged.firstMatch(normalized);
    if (t != null) {
      final n = _toDouble(t.group(1));
      if (n != null && n > 0) return n;
    }

    final allNums = RegExp(r'\b([0-9][0-9,]*(?:\.[0-9]{1,2})?)\b').allMatches(normalized);
    double? best;
    for (final m in allNums) {
      final v = _toDouble(m.group(1));
      if (v == null) continue;
      if (v < 10) continue;
      if (best == null || v > best) best = v;
    }
    return best;
  }

  static double? _toDouble(String? s) {
    if (s == null) return null;
    return double.tryParse(s.replaceAll(',', '').trim());
  }

  static String? _extractReceiver(String text) {
    final lines = text.split(RegExp(r'[\r\n]+')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    final inlinePatterns = <RegExp>[
      // Handles "To Account: MUHAMMAD MUDDASSIR 1029xxx6940" and similar OCR shapes.
      RegExp(
        r'(?:beneficiary\s*name|to\s*account|to|sent\s*to|receiver|received\s*by|account\s*name)\s*[:\-]?\s*([A-Za-z]{2,}(?:\s+[A-Za-z]{2,}){0,4})',
        caseSensitive: false,
      ),
      // Handles bank-account blocks where the next token can still be recipient name.
      RegExp(r'(?:bank\s*account)\s*[:\-]?\s*([A-Za-z]{2,}(?:\s+[A-Za-z]{2,}){0,4})', caseSensitive: false),
    ];
    for (final line in lines) {
      for (final rx in inlinePatterns) {
        final m = rx.firstMatch(line);
        final v = m?.group(1)?.trim();
        if (_isLikelyPersonName(v)) return v;
      }
    }

    // Label on one line, receiver value on following line(s).
    for (int i = 0; i < lines.length; i++) {
      final l = lines[i];
      final labelOnly = _isReceiverLabelLine(l);
      if (!labelOnly) continue;

      for (int j = i + 1; j <= i + 6 && j < lines.length; j++) {
        final next = lines[j].trim();
        if (_looksLikeBankOrNoise(next)) continue;
        if (_looksMaskedAccount(next)) continue;
        if (_isLikelyPersonName(next)) return next;
      }
    }

    // Pattern used in dark transfer slips: "... to <NAME> - Account Number: ****6940"
    final joined = lines.join(' ');
    final toInline = RegExp(
      r'\bto\s+([A-Za-z][A-Za-z .]{2,60})\s*[-|]\s*account\s*number',
      caseSensitive: false,
    ).firstMatch(joined);
    final toName = toInline?.group(1)?.trim();
    if (_isLikelyPersonName(toName)) return toName;

    final sentToInline = RegExp(
      r'\bsent\s*to\s+([A-Za-z]{2,}(?:\s+[A-Za-z]{2,}){0,4})',
      caseSensitive: false,
    ).firstMatch(joined);
    final sentToName = sentToInline?.group(1)?.trim();
    if (_isLikelyPersonName(sentToName)) return sentToName;

    final nearMarker = _pickReceiverNearMarkers(lines);
    if (_isLikelyPersonName(nearMarker)) return nearMarker;

    return null;
  }

  static bool _isReceiverLabelLine(String line) {
    final normalized = line.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    if (normalized.isEmpty) return false;
    return normalized == 'to' ||
        normalized.contains('toaccount') ||
        normalized.contains('beneficiaryname') ||
        normalized.contains('sentto') ||
        normalized.contains('receiver') ||
        normalized.contains('receivedby') ||
        normalized.contains('accountname') ||
        normalized == 'name' ||
        normalized.contains('bankaccount');
  }

  static String? _pickReceiverNearMarkers(List<String> lines) {
    final markers = <int>[];
    for (int i = 0; i < lines.length; i++) {
      final n = lines[i].toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
      if (n == 'to' || n.contains('toaccount') || n.contains('beneficiaryname') || n.contains('sentto')) {
        markers.add(i);
      }
    }
    if (markers.isEmpty) return null;

    String? best;
    int bestScore = -1;
    for (final m in markers) {
      final end = (m + 8 < lines.length) ? m + 8 : lines.length - 1;
      for (int i = m + 1; i <= end; i++) {
        final line = lines[i].trim();
        if (!_isLikelyPersonName(line)) continue;
        int score = 0;
        final words = line.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
        if (words >= 2) score += 2;
        if (line.toUpperCase() == line) score += 2;
        if (line.length >= 10) score += 1;
        if (score > bestScore) {
          bestScore = score;
          best = line;
        }
      }
    }
    return best;
  }

  static bool _isLikelyPersonName(String? s) {
    if (s == null) return false;
    final v = s.trim();
    if (v.isEmpty || v.length < 3 || v.length > 60) return false;
    if (!RegExp(r'^[A-Za-z][A-Za-z .]+$').hasMatch(v)) return false;
    final lower = v.toLowerCase();
    if (_looksLikeBankOrNoise(v)) return false;
    const blocked = <String>{
      'transaction successful',
      'money sent successfully',
      'funding source',
      'bank account',
      'from account',
      'to account',
      'sent by',
      'beneficiary name',
      'purpose',
      'channel',
      'via ibft',
      'easy paisa',
      'easypaisa account',
    };
    return !blocked.contains(lower);
  }

  static bool _looksMaskedAccount(String s) {
    final v = s.toLowerCase();
    if (v.contains('iban')) return true;
    if (v.contains('*')) return true;
    if (RegExp(r'^[0-9xX*\- ]{6,}$').hasMatch(v)) return true;
    return false;
  }

  static bool _looksLikeBankOrNoise(String s) {
    final v = s.trim().toLowerCase();
    if (v.isEmpty) return true;
    return v.contains('bank') ||
        v.contains('account') ||
        v.contains('transaction') ||
        v.contains('money') ||
        v.contains('successful') ||
        v.contains('reference') ||
        v.contains('id') ||
        v.contains('amount') ||
        v.contains('purpose') ||
        v.contains('channel') ||
        v.contains('funding source') ||
        v.contains('sent by') ||
        v.contains('from account');
  }
}
