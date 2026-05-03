import 'package:flutter/material.dart';

import '../models/customer.dart';
import '../utils/format.dart';
import 'app_panels.dart';

String customerSummarySearchText(Customer customer) {
  return [
    customer.id,
    customer.name,
    customer.displayName,
    customer.contact,
  ].join(' ').toLowerCase();
}

class CustomerSummaryCard extends StatelessWidget {
  final Customer customer;
  final String sortLabel;
  final double total;
  final double paid;
  final double remaining;
  final VoidCallback? onTap;
  final Widget? actions;
  final bool showRemainingPill;
  final int maxTitleLines;
  final Color backgroundColor;
  final EdgeInsetsGeometry? margin;

  const CustomerSummaryCard({
    super.key,
    required this.customer,
    required this.sortLabel,
    required this.total,
    required this.paid,
    required this.remaining,
    this.onTap,
    this.actions,
    this.showRemainingPill = false,
    this.maxTitleLines = 1,
    this.backgroundColor = const Color(0xFFF8FAFC),
    this.margin,
  });

  Widget _content(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                '${customer.id} - ${customer.name}',
                maxLines: maxTitleLines,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFF172033),
                    ),
              ),
            ),
            if (showRemainingPill) ...[
              const SizedBox(width: 10),
              AppStatusPill(
                text: 'Rs ${fmt0(remaining)}',
                color: const Color(0xFFFF8A00),
              ),
            ],
          ],
        ),
        if (customer.contact.trim().isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            customer.contact.trim(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFF566074),
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
        if (customer.displayName.trim().isNotEmpty &&
            customer.displayName.trim() != customer.name.trim()) ...[
          const SizedBox(height: 4),
          Text(
            'Invoice name: ${customer.displayName}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: Color(0xFF667085)),
          ),
        ],
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            AppMetaChip(text: 'Sort $sortLabel'),
            AppMetaChip(text: 'Total Rs ${fmt0(total)}'),
            AppMetaChip(text: 'Paid Rs ${fmt0(paid)}'),
            AppMetaChip(text: 'Remaining Rs ${fmt0(remaining)}'),
          ],
        ),
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
