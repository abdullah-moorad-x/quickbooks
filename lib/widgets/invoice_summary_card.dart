import 'package:flutter/material.dart';

import '../models/invoice.dart';
import '../utils/format.dart';
import 'app_panels.dart';

String invoiceSummarySearchText(Invoice invoice) {
  final lineText = invoice.lines
      .map(
        (line) =>
            '${line.typeLabel} ${line.brand} ${line.qty} ${fmt0(line.rate)}',
      )
      .join(' ');
  return [
    invoice.sNo,
    invoice.customer,
    invoice.customerDisplay ?? '',
    invoice.customerId,
    invoice.contact,
    invoice.address,
    invoice.site,
    invoice.date,
    if (invoice.isReturn) 'return returned',
    if (invoice.returnOfInvoiceNo != null)
      'invoice ${invoice.returnOfInvoiceNo}',
    lineText,
  ].join(' ').toLowerCase();
}

class InvoiceSummaryCard extends StatelessWidget {
  final Invoice invoice;
  final VoidCallback? onTap;
  final Widget? actions;
  final bool showContactLine;
  final bool showTotalPill;
  final int maxTitleLines;
  final Color backgroundColor;
  final EdgeInsetsGeometry margin;

  const InvoiceSummaryCard({
    super.key,
    required this.invoice,
    this.onTap,
    this.actions,
    this.showContactLine = false,
    this.showTotalPill = false,
    this.maxTitleLines = 1,
    this.backgroundColor = const Color(0xFFF8FAFC),
    this.margin = const EdgeInsets.only(bottom: 10),
  });

  String get _title {
    final name = invoice.customer.trim();
    final address = invoice.address.trim();
    final prefix =
        invoice.isReturn ? 'Return #${invoice.sNo}' : '#${invoice.sNo}';
    if (address.isEmpty) return '$prefix  $name';
    return '$prefix  $name  -  $address';
  }

  List<Widget> get _summaryChips {
    return [
      AppMetaChip(icon: Icons.calendar_today_outlined, text: invoice.date),
      if (invoice.isReturn && invoice.returnOfInvoiceNo != null)
        AppMetaChip(
          icon: Icons.assignment_return_outlined,
          text: 'From #${invoice.returnOfInvoiceNo}',
        ),
      AppMetaChip(
        icon: Icons.local_shipping_outlined,
        text: 'Cartage ${fmt0(invoice.cartage)}',
      ),
      AppMetaChip(
        icon: Icons.receipt_long_outlined,
        text: 'Total ${fmt0(invoice.balance)}',
      ),
      AppMetaChip(
        icon: Icons.account_balance_wallet_outlined,
        text: 'Paid ${fmt0(invoice.paid)}',
      ),
      AppMetaChip(
        icon: Icons.hourglass_bottom_outlined,
        text: 'Rem ${fmt0(invoice.remaining)}',
      ),
    ];
  }

  List<String> get _itemChips {
    return invoice.lines
        .where((line) => line.qty != 0)
        .map((line) {
          final brand = line.brand.trim();
          final brandPart = brand.isEmpty ? '' : ' - $brand';
          return '${line.typeLabel}$brandPart: ${line.qty} @ ${fmt0(line.rate)}';
        })
        .where((text) => text.trim().isNotEmpty)
        .toList();
  }

  Widget _content(BuildContext context) {
    final itemChips = _itemChips;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                _title,
                maxLines: maxTitleLines,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFF172033),
                    ),
              ),
            ),
            if (showTotalPill) ...[
              const SizedBox(width: 10),
              AppStatusPill(
                text: 'Rs ${fmt0(invoice.balance)}',
                color: const Color(0xFF4B5DFF),
              ),
            ],
          ],
        ),
        if (showContactLine &&
            (invoice.customerId.trim().isNotEmpty ||
                invoice.contact.trim().isNotEmpty ||
                invoice.site.trim().isNotEmpty)) ...[
          const SizedBox(height: 8),
          Text(
            [
              if (invoice.customerId.trim().isNotEmpty)
                invoice.customerId.trim(),
              if (invoice.contact.trim().isNotEmpty) invoice.contact.trim(),
              if (invoice.site.trim().isNotEmpty) invoice.site.trim(),
            ].join('  |  '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFF667085),
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: _summaryChips),
        if (itemChips.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: itemChips
                .map(
                  (text) => AppMetaChip(
                    text: text,
                    backgroundColor: const Color(0xFFF3F6FA),
                    borderColor: const Color(0xFFDCE5EE),
                    foregroundColor: const Color(0xFF51607A),
                  ),
                )
                .toList(),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = actions == null
        ? _content(context)
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _content(context)),
              const SizedBox(width: 12),
              actions!,
            ],
          );

    return AppPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: AppSoftCard(
        margin: margin,
        padding: const EdgeInsets.all(14),
        backgroundColor: backgroundColor,
        child: body,
      ),
    );
  }
}
