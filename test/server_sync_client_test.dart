import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quickbill_by_abdullah/models/payment.dart';
import 'package:quickbill_by_abdullah/services/server_sync_client.dart';

Future<void> _withResponse(
  int statusCode,
  String body,
  Future<void> Function(String baseUrl) run,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final subscription = server.listen((request) async {
    request.response.statusCode = statusCode;
    request.response.headers.contentType = ContentType.html;
    request.response.write(body);
    await request.response.close();
  });
  try {
    await run('http://127.0.0.1:${server.port}');
  } finally {
    await subscription.cancel();
    await server.close(force: true);
  }
}

void main() {
  test('translates Cloudflare tunnel error 1033', () async {
    await _withResponse(
      530,
      '<html><title>Cloudflare</title><p>Error code 1033</p></html>',
      (baseUrl) async {
        await expectLater(
          ServerSyncClient.testConnection(baseUrl),
          throwsA(
            isA<ServerSyncException>()
                .having(
                  (error) => error.message,
                  'message',
                  contains('healthy QuickBill tunnel'),
                )
                .having(
                  (error) => error.message,
                  'code',
                  contains('CF 1033'),
                ),
          ),
        );
      },
    );
  });

  test('translates Cloudflare bad gateway response', () async {
    await _withResponse(502, '<html><title>Cloudflare</title></html>',
        (baseUrl) async {
      await expectLater(
        ServerSyncClient.testConnection(baseUrl),
        throwsA(
          isA<ServerSyncException>().having(
            (error) => error.message,
            'message',
            allOf(contains('cannot reach'), contains('HTTP 502')),
          ),
        ),
      );
    });
  });

  test('explains a successful HTML response as tunnel misconfiguration',
      () async {
    await _withResponse(200, '<html><title>Cloudflare Access</title></html>',
        (baseUrl) async {
      await expectLater(
        ServerSyncClient.testConnection(baseUrl),
        throwsA(
          isA<ServerSyncException>().having(
            (error) => error.message,
            'message',
            contains('web page instead of QuickBill data'),
          ),
        ),
      );
    });
  });

  test('rejects incomplete Cloudflare URLs clearly', () async {
    await expectLater(
      ServerSyncClient.testConnection('quickbill.example.com'),
      throwsA(
        isA<ServerSyncException>().having(
          (error) => error.message,
          'message',
          contains('[INVALID URL]'),
        ),
      ),
    );
  });

  test('reuses a login token for repeated actions', () async {
    var loginRequests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      await request.drain<void>();
      if (request.uri.path == '/auth/login') {
        loginRequests++;
        request.response.write(
          '{"token":"cached-token","user":{"id":"u1","username":"owner","displayName":"Owner","role":"admin"}}',
        );
      } else {
        request.response.statusCode = HttpStatus.notFound;
        request.response.write('{"error":"Not found"}');
      }
      await request.response.close();
    });
    final baseUrl = 'http://127.0.0.1:${server.port}';
    try {
      await ServerSyncClient.authenticateUser(
        baseUrl: baseUrl,
        username: 'owner',
        passcode: '1234',
      );
      await ServerSyncClient.authenticateUser(
        baseUrl: baseUrl,
        username: 'owner',
        passcode: '1234',
      );
      expect(loginRequests, 1);
    } finally {
      await subscription.cancel();
      await server.close(force: true);
    }
  });

  test('refreshes an expired token and retries the submit once', () async {
    var loginRequests = 0;
    var paymentRequests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      await request.drain<void>();
      if (request.uri.path == '/auth/login') {
        loginRequests++;
        request.response.write(
          '{"token":"token-$loginRequests","user":{"id":"u1","username":"owner","displayName":"Owner","role":"admin"}}',
        );
      } else if (request.uri.path == '/payments') {
        paymentRequests++;
        final authorization = request.headers.value('authorization') ?? '';
        if (authorization == 'Bearer token-1') {
          request.response.statusCode = HttpStatus.unauthorized;
          request.response.write('{"error":"Unauthorized"}');
        } else {
          request.response.write('{"ok":true}');
        }
      }
      await request.response.close();
    });
    final baseUrl = 'http://127.0.0.1:${server.port}';
    try {
      await ServerSyncClient.authenticateUser(
        baseUrl: baseUrl,
        username: 'owner',
        passcode: '1234',
      );
      await ServerSyncClient.submitPayment(
        baseUrl: baseUrl,
        username: 'owner',
        passcode: '1234',
        payment: const PaymentEntry(
          id: 'MPAY-test',
          date: '13/07/2026',
          customerId: 'C-1',
          customer: 'Test Customer',
          type: PaymentType.cash,
          amount: 100,
        ),
      );
      expect(loginRequests, 2);
      expect(paymentRequests, 2);
    } finally {
      await subscription.cancel();
      await server.close(force: true);
    }
  });
}
