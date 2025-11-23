import 'dart:io';
import 'dart:typed_data';

Future<File> safeWriteBytes(File target, Uint8List bytes, {int maxTries = 20}) async {
  Future<File> tryWrite(File f) async { await f.writeAsBytes(bytes, flush: true); return f; }
  try { return await tryWrite(target); } catch (_) {
    final p = target.path;
    final dot = p.lastIndexOf('.');
    final base = dot > 0 ? p.substring(0, dot) : p;
    final ext = dot > 0 ? p.substring(dot) : '';
    for (int i = 1; i <= maxTries; i++) {
      final alt = File('${base}_$i$ext');
      try { return await tryWrite(alt); } catch (_) {}
    }
    rethrow;
  }
}
