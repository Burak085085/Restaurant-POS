import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/main.dart';
import 'package:restaurant_pos/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

// These tests go through the real SQLite repository. The older persistence
// tests use MemoryStoreRepository, which stores the whole JSON blob and
// therefore cannot notice fields that the normalized tables drop.
void main() {
  late Directory directory;
  late SqliteStoreRepository repository;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('restaurant-pos-roundtrip-');
    repository = SqliteStoreRepository(
      databasePath: '${directory.path}/pos.sqlite3',
      backupDirectoryPath: directory.path,
    );
  });

  tearDown(() async {
    await repository.close();
    await directory.delete(recursive: true);
  });

  test('SQLite keeps the timestamp format version so timestamps are not shifted on every launch', () async {
    final first = Pos(repository: repository);
    first.registerSessions.add(RegisterSession(
        id: 1, openedAt: '2026-11-22T00:00:00.000Z', openingCash: 0));
    first.cashMovements.add(CashMovement(
        id: 1, sessionId: 1, at: '2026-11-22T01:02:03.000Z',
        type: 'Giriş', amount: 100, note: 'test'));
    first.save();
    await first.flush();

    for (var launch = 0; launch < 3; launch++) {
      final restored = Pos(repository: repository);
      await restored.load();
      expect(restored.cashMovements.single.at, '2026-11-22T01:02:03.000Z');
      expect(restored.registerSessions.single.openedAt, '2026-11-22T00:00:00.000Z');
      await restored.flush();
    }
  });

  test('refund records and the stock-returned flag survive a SQLite reload', () async {
    final store = Pos(repository: repository);
    store.staff.firstWhere((member) => member.name == 'Admin').setPin('8642');
    final product = store.products.first;
    product.stock = 5;
    final table = store.tables.first;
    expect(store.add(table, product), isTrue);
    expect(store.sendKitchen(table), isTrue);
    expect(store.openRegister(5000), isTrue);
    expect(store.checkout(table, [PaymentPart('Kart', product.price)]), isTrue);
    final originalIndex = store.sales.length - 1;
    expect(store.refundSale(originalIndex, product.price, 'Hatalı ürün', '8642',
        returnStock: true), isTrue);
    await store.flush();

    final restored = Pos(repository: repository);
    await restored.load();
    expect(restored.recoveryRequired, isFalse);
    expect(restored.sales.last.isRefund, isTrue);
    expect(restored.sales.last.refundOfSaleIndex, originalIndex);
    expect(restored.sales.last.reason, 'Hatalı ürün');
    expect(restored.sales[originalIndex].isRefund, isFalse);
    expect(restored.sales[originalIndex].stockReturned, isTrue);
    expect(restored.remainingRefundable(originalIndex), 0);
  });

  test('kitchen cancellation notices survive a SQLite reload', () async {
    final store = Pos(repository: repository);
    final product = store.products.first;
    final table = store.tables.first;
    expect(store.add(table, product), isTrue);
    expect(store.sendKitchen(table), isTrue);
    expect(store.cancelSentLine(table, table.items.single, 1, 'Müşteri vazgeçti', '1234'), isTrue);
    await store.flush();

    final restored = Pos(repository: repository);
    await restored.load();
    expect(restored.kitchenNotices, hasLength(1));
    expect(restored.kitchenNotices.single.reason, 'Müşteri vazgeçti');
    expect(restored.kitchenNotices.single.acknowledged, isFalse);
  });
}
