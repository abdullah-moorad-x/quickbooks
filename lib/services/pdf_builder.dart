import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../core/constants.dart';
import '../models/invoice.dart';
import '../utils/format.dart';

Future<ui.Image> _loadUiImage(Uint8List data) {
  final c = Completer<ui.Image>();
  ui.decodeImageFromList(data, (ui.Image img) => c.complete(img));
  return c.future;
}

class PdfBuilder {
  static pw.Font? _fontRegular;
  static pw.Font? _fontBold;
  static Future<void> _ensureFonts() async {
    if (_fontRegular != null && _fontBold != null) return;
    final reg =
        await rootBundle.load('assets/fonts/Poppins/Poppins-Regular.ttf');
    final bold = await rootBundle.load('assets/fonts/Poppins/Poppins-Bold.ttf');
    _fontRegular = pw.Font.ttf(reg);
    _fontBold = pw.Font.ttf(bold);
  }

  static const lift = -0.010, liftBrand = -0.010, liftTotals = -0.010;
  static const liftName = -0.013;
  static const xSno = 0.1247, ySno = 0.2390;
  static const xDate = 0.7995, yDate = 0.2390;
  static const xName = 0.1057, yName = 0.2797;
  static const xContact = 0.7561, yContact = 0.2797;
  static const xAddr = 0.1599, yAddr = 0.3237;
  static const rowsY = <double>[0.4352, 0.4845, 0.5413, 0.5906, 0.6356];
  static const colQty = 0.5298, colRate = 0.6531, colAmt = 0.7886;
  static const brandXs = <double>[0.207, 0.207, 0.337, 0.237, 0.237];
  static const xTotal = 0.7886, yTotal = 0.6892;
  static const xCart = 0.7886, yCart = 0.7245;
  static const xBal = 0.7886, yBal = 0.7621;
  static const liftTotalRow = -0.018;

  static double fitToWidth(String text, double availablePx,
      {double base = 17, double min = 9, double avgCharFactor = 0.53}) {
    text = text.trim();
    if (text.isEmpty) return base;
    final estWidth = text.length * base * avgCharFactor;
    if (estWidth <= availablePx) return base;
    final size = availablePx / (text.length * avgCharFactor);
    if (size.isNaN || size.isInfinite) return base;
    return size.clamp(min, base);
  }

  static Future<Uint8List> build(Invoice inv) async {
    await _ensureFonts();
    final jpg = await rootBundle.load('assets/template.jpg');
    final bytes = jpg.buffer.asUint8List();
    final bg = pw.MemoryImage(bytes);
    final img = await _loadUiImage(bytes);
    final page = PdfPageFormat(img.width.toDouble(), img.height.toDouble());
    final theme = pw.ThemeData.withFont(base: _fontRegular!, bold: _fontBold!);

    pw.Widget place(String t, double x, double y,
            {double size = 12, pw.FontWeight? fw}) =>
        pw.Positioned(
            left: page.width * x,
            top: page.height * y,
            child: pw.Text(t,
                style: pw.TextStyle(fontSize: size, fontWeight: fw)));

    final doc = pw.Document(theme: theme);
    final pdfRows = <Map<String, dynamic>>[];
    for (final t in kItemTypes) {
      final same = inv.lines.where((l) => l.typeLabel == t).toList();
      final brandParts = <String>[];
      final qtyParts = <String>[];
      final rateParts = <String>[];
      int qtySum = 0;
      double amountSum = 0.0;
      for (final l in same) {
        if (l.qty != 0) {
          final b = l.brand.trim();
          if (b.isNotEmpty) brandParts.add(b);
          qtyParts.add('${l.qty}');
          if (l.rate > 0) rateParts.add(fmt0(l.rate));
        }
        qtySum += l.qty;
        amountSum += l.qty * l.rate;
      }
      final rateAvg = qtySum != 0 ? amountSum / qtySum : 0.0;
      pdfRows.add({
        'brand': qtySum != 0 ? brandParts.join(' + ') : '',
        'qtyText': qtyParts.isEmpty ? '0' : qtyParts.join(' + '),
        'rateText': rateParts.isEmpty ? '0.00' : rateParts.join(' + '),
        'amount': amountSum,
        'qtySum': qtySum,
        'rateAvg': rateAvg
      });
    }
    doc.addPage(pw.Page(
        pageFormat: page,
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Stack(children: [
              pw.Positioned.fill(child: pw.Image(bg, fit: pw.BoxFit.cover)),
              place('${inv.sNo}', xSno, ySno + lift,
                  size: 16, fw: pw.FontWeight.bold),
              place(inv.date, xDate, yDate + lift, size: 16),
              place((inv.customerDisplay ?? inv.customer), xName,
                  yName + liftName,
                  size: 20, fw: pw.FontWeight.bold),
              place(inv.contact, xContact, yContact + lift, size: 18),
              place(inv.address, xAddr, yAddr + lift, size: 18),
              for (int i = 0; i < pdfRows.length && i < rowsY.length; i++) ...[
                pw.Positioned(
                    left: page.width * brandXs[i],
                    top: page.height * (rowsY[i] + liftBrand),
                    child: pw.Container(
                      width: page.width * (colQty - brandXs[i] - 0.01),
                      padding: const pw.EdgeInsets.symmetric(
                          horizontal: 1, vertical: 0.5),
                      child: () {
                        final txt = (pdfRows[i]['brand'] as String).trim();
                        final size = fitToWidth(
                            txt, page.width * (colQty - brandXs[i] - 0.01),
                            base: 17, min: 9);
                        return pw.Text(txt,
                            style: pw.TextStyle(
                                fontSize: size, fontWeight: pw.FontWeight.bold),
                            maxLines: 1,
                            overflow: pw.TextOverflow.clip);
                      }(),
                    )),
                pw.Positioned(
                    left: page.width * colQty,
                    top: page.height * (rowsY[i] + liftBrand),
                    child: pw.Container(
                      width: page.width * (colRate - colQty - 0.01),
                      alignment: pw.Alignment.centerLeft,
                      child: () {
                        final txt = pdfRows[i]['qtyText'] as String;
                        final size = fitToWidth(
                            txt, page.width * (colRate - colQty - 0.01),
                            base: 16, min: 9);
                        return pw.Text(txt,
                            style: pw.TextStyle(fontSize: size));
                      }(),
                    )),
                pw.Positioned(
                    left: page.width * colRate,
                    top: page.height * (rowsY[i] + liftBrand),
                    child: pw.Container(
                      width: page.width * (colAmt - colRate - 0.01),
                      alignment: pw.Alignment.centerLeft,
                      child: () {
                        final txt = pdfRows[i]['rateText'] as String;
                        final size = fitToWidth(
                            txt, page.width * (colAmt - colRate - 0.01),
                            base: 16, min: 8);
                        return pw.Text(txt,
                            style: pw.TextStyle(fontSize: size));
                      }(),
                    )),
                place(fmt0(pdfRows[i]['amount'] as double), colAmt,
                    rowsY[i] + liftBrand,
                    size: 16, fw: pw.FontWeight.bold),
              ],
              place(fmt0(inv.total), xTotal, yTotal + liftTotalRow,
                  size: 20, fw: pw.FontWeight.bold),
              place(fmt0(inv.cartage), xCart, yCart + liftTotals, size: 18),
              place(fmt0(inv.balance), xBal, yBal + liftTotals,
                  size: 20, fw: pw.FontWeight.bold),
            ])));
    return doc.save();
  }
}
