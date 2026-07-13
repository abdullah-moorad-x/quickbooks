import 'dart:async';

import '../models/mobile_access.dart';
import 'mobile_sync_store.dart';
import 'server_sync_client.dart';

class MobileDraftRetryService {
  static Timer? _timer;
  static bool _retrying = false;

  static void start(AppUser user) {
    stop();
    if (user.role == UserRole.viewer) return;
    unawaited(retryNow(user));
    _timer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(retryNow(user)),
    );
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
  }

  static Future<void> retryNow(AppUser user) async {
    if (_retrying || user.role == UserRole.viewer) return;
    _retrying = true;
    try {
      final config = await MobileAccessStore.loadServerConfig();
      if (config.baseUrl.trim().isEmpty) return;
      if (user.role == UserRole.admin) {
        final paymentDeletes =
            await MobileAccessStore.loadOutgoingPaymentDeletes();
        for (final paymentId in paymentDeletes) {
          final attemptAt = DateTime.now().toIso8601String();
          try {
            await ServerSyncClient.deletePayment(
              baseUrl: config.baseUrl,
              username: user.username,
              passcode: user.passcode,
              paymentId: paymentId,
            );
            await MobileAccessStore.removeOutgoingPaymentDelete(paymentId);
            await MobileAccessStore.addSyncLog(
              SyncLogEntry(
                id: MobileAccessStore.nextSyncLogId(),
                createdAt: attemptAt,
                direction: SyncLogDirection.outgoing,
                status: SyncLogStatus.success,
                entityType: 'payment',
                entityId: paymentId,
                summary: 'Queued payment delete delivered to laptop',
              ),
            );
          } on ServerSyncException catch (e) {
            await MobileAccessStore.addSyncLog(
              SyncLogEntry(
                id: MobileAccessStore.nextSyncLogId(),
                createdAt: attemptAt,
                direction: SyncLogDirection.outgoing,
                status: SyncLogStatus.warning,
                entityType: 'payment',
                entityId: paymentId,
                summary: 'Queued payment delete retry failed',
                details: e.message,
              ),
            );
          }
        }
        final payments = await MobileAccessStore.loadOutgoingPayments();
        for (final payment in payments) {
          final attemptAt = DateTime.now().toIso8601String();
          try {
            await ServerSyncClient.submitPayment(
              baseUrl: config.baseUrl,
              username: user.username,
              passcode: user.passcode,
              payment: payment,
            );
            await MobileAccessStore.removeOutgoingPayment(payment.id);
            await MobileAccessStore.addSyncLog(
              SyncLogEntry(
                id: MobileAccessStore.nextSyncLogId(),
                createdAt: attemptAt,
                direction: SyncLogDirection.outgoing,
                status: SyncLogStatus.success,
                entityType: 'payment',
                entityId: payment.id,
                summary: 'Queued payment delivered to laptop',
                details: payment.customer,
              ),
            );
          } on ServerSyncException catch (e) {
            await MobileAccessStore.addSyncLog(
              SyncLogEntry(
                id: MobileAccessStore.nextSyncLogId(),
                createdAt: attemptAt,
                direction: SyncLogDirection.outgoing,
                status: SyncLogStatus.warning,
                entityType: 'payment',
                entityId: payment.id,
                summary: 'Queued payment retry failed',
                details: e.message,
              ),
            );
          }
        }
      }
    } finally {
      _retrying = false;
    }
  }
}
