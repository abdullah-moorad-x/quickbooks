import 'dart:io';
import 'package:path_provider/path_provider.dart';

const String? kCustomBaseDir = null;

Future<Directory> baseDir() async {
  if (kCustomBaseDir != null && kCustomBaseDir!.isNotEmpty) {
    final d = Directory(kCustomBaseDir!);
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }
  final docs = await getApplicationDocumentsDirectory();
  final d = Directory('${docs.path}${Platform.pathSeparator}QuickBill');
  if (!await d.exists()) await d.create(recursive: true);
  return d;
}

Future<Directory> subdir(String name) async {
  final base = await baseDir();
  final d = Directory('${base.path}${Platform.pathSeparator}$name');
  if (!await d.exists()) await d.create(recursive: true);
  return d;
}
