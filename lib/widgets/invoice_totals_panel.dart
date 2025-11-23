import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

class InvoiceTotalsPanel extends StatelessWidget {
  const InvoiceTotalsPanel({
    super.key,
    required this.cartageController,
    required this.total,
    required this.balance,
    required this.onSavePdf,
    required this.onWhatsApp,
    this.accentColor = const Color(0xFF007C89),
  });

  final TextEditingController cartageController;
  final num total;
  final num balance;
  final VoidCallback onSavePdf;
  final VoidCallback onWhatsApp;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    TextStyle numStyle({FontWeight weight = FontWeight.w600, Color? color}) =>
        TextStyle(
          fontWeight: weight,
          color: color ?? const Color(0xFF0F172A),
          fontSize: 18,
        );
    String fmt0(num n) => n.toStringAsFixed(0);

    InputDecoration cartageDecoration() => InputDecoration(
          hintText: '0',
          filled: true,
          fillColor: const Color(0xFFF0F4F9),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Colors.transparent),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Colors.transparent),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: accentColor, width: 1.2),
          ),
        );

    Widget metric(String label, String value, {bool highlight = false}) {
      return Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: Color(0xFF374151),
              ),
            ),
          ),
          Text(
            value,
            style: numStyle(
                weight: highlight ? FontWeight.w800 : FontWeight.w600,
                color: highlight ? accentColor : null),
          ),
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE4E7EC)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x11000000),
            blurRadius: 12,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Cartage (courier fee)',
                  style: TextStyle(
                    color: Color(0xFF4F5A67),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              SizedBox(
                width: 88,
                child: TextField(
                  controller: cartageController,
                  textAlign: TextAlign.right,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: false, signed: false),
                  decoration: cartageDecoration(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          metric('Total', fmt0(total)),
          const SizedBox(height: 6),
          metric('Balance (Total + Cartage)', fmt0(balance), highlight: true),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Tooltip(
                  message: 'Save invoice, export PDF',
                  child: FilledButton.icon(
                    onPressed: onSavePdf,
                    style: FilledButton.styleFrom(
                      backgroundColor: accentColor,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(38),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    icon: const Icon(Icons.picture_as_pdf_rounded),
                    label:
                        const Text('Save PDF', overflow: TextOverflow.ellipsis),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Tooltip(
                  message: 'Auto-save, open folder and WhatsApp',
                  child: FilledButton.icon(
                    onPressed: onWhatsApp,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF1B92FF),
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(38),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    icon: const FaIcon(FontAwesomeIcons.whatsapp),
                    label: const Text('WhatsApp...',
                        overflow: TextOverflow.ellipsis),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
