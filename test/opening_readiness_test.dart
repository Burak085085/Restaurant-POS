import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/advanced_features.dart';
import 'package:restaurant_pos/main.dart';
import 'package:restaurant_pos/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Record id generation', () {
    test('ids are strictly increasing even inside one clock tick', () {
      final pos = Pos(repository: MemoryStoreRepository());
      final ids = List<int>.generate(500, (_) => pos.nextRecordId());
      for (var index = 1; index < ids.length; index++) {
        expect(ids[index], greaterThan(ids[index - 1]));
      }
      expect(ids.toSet().length, ids.length);
    });

    test('ids continue above records loaded from storage', () async {
      final repository = MemoryStoreRepository();
      final first = Pos(repository: repository);
      expect(first.stockChange(first.products.first, 5), isTrue);
      await first.flush();
      final loadedId = first.stockMovements.single.id;

      final restored = Pos(repository: repository);
      await restored.load();
      expect(restored.nextRecordId(), greaterThan(loadedId));
    });

    test('multi-product checkout persists every stock movement in SQLite', () async {
      SharedPreferences.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp('pos-unique-ids-');
      final repository = SqliteStoreRepository(
        databasePath: '${directory.path}/restaurant-pos.sqlite3',
        backupDirectoryPath: '${directory.path}/backups',
      );
      try {
        final pos = Pos(repository: repository);
        final table = pos.tables.first;
        for (final product in pos.products.take(6)) {
          expect(pos.add(table, product), isTrue);
        }
        expect(pos.sendKitchen(table), isTrue);
        final total = table.total;
        expect(pos.checkout(table, [PaymentPart('Kart', total)]), isTrue);
        await pos.flush();
        expect(pos.persistenceFailed, isFalse, reason: pos.persistenceError);

        final reloaded = Pos(repository: repository);
        await reloaded.load();
        final saleMovements =
            reloaded.stockMovements.where((m) => m.type == 'Satış').toList();
        expect(saleMovements.length, 6);
        expect(saleMovements.map((m) => m.id).toSet().length, 6);
        expect(reloaded.sales.single.total, total);
      } finally {
        await repository.close();
        await directory.delete(recursive: true);
      }
    });
  });

  group('Audit retention', () {
    test('ordinary rows are capped but critical rows are never trimmed', () {
      final pos = Pos(repository: MemoryStoreRepository());
      pos.log('Ödeme', 'Masa 1: 10,00 ₼');
      pos.log('Satış iadesi', 'Satış #1: 2,00 ₼');
      pos.log('Güvenlik', 'Başarısız PIN denemesi (1/5) · staff:Admin');
      pos.log('Kasa açıldı', 'Açılış nakdi: 50,00 ₼');
      pos.log('İndirim', 'Masa 2: %10 · Personel');
      pos.log('Personel', 'Personel eklendi: Ali (Kasiyer)');
      for (var index = 0; index < Pos.ordinaryAuditLimit + 500; index++) {
        pos.log('Sipariş', 'Masa 3: ürün $index');
      }
      final ordinary = pos.audit.where((e) => !Pos.isCriticalAudit(e)).toList();
      expect(ordinary.length, Pos.ordinaryAuditLimit);
      // Newest ordinary rows are kept, oldest are dropped.
      expect(ordinary.first.detail, 'Masa 3: ürün ${Pos.ordinaryAuditLimit + 499}');
      expect(ordinary.any((e) => e.detail == 'Masa 3: ürün 0'), isFalse);
      for (final action in ['Ödeme', 'Satış iadesi', 'Güvenlik', 'Kasa açıldı', 'İndirim', 'Personel']) {
        expect(pos.audit.where((e) => e.action == action).length, 1, reason: action);
      }
    });

    test('critical audit rows survive SQLite reload and backup restore', () async {
      SharedPreferences.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp('pos-audit-retention-');
      final repository = SqliteStoreRepository(
        databasePath: '${directory.path}/restaurant-pos.sqlite3',
        backupDirectoryPath: '${directory.path}/backups',
      );
      try {
        final pos = Pos(repository: repository);
        pos.log('Satış iadesi', 'kritik-iade');
        pos.log('Güvenlik', 'kritik-pin');
        for (var index = 0; index < Pos.ordinaryAuditLimit + 50; index++) {
          pos.log('Mutfak', 'sıradan $index');
        }
        pos.save();
        await pos.flush();

        final reloaded = Pos(repository: repository);
        await reloaded.load();
        expect(reloaded.audit.any((e) => e.detail == 'kritik-iade'), isTrue);
        expect(reloaded.audit.any((e) => e.detail == 'kritik-pin'), isTrue);
        expect(reloaded.audit.where((e) => !Pos.isCriticalAudit(e)).length,
            Pos.ordinaryAuditLimit);

        final memory = MemoryStoreRepository();
        final source = Pos(repository: memory);
        source.audit = List<Audit>.from(reloaded.audit);
        source.save();
        await source.flush();
        final payload = memory.value!;

        final target = Pos(repository: MemoryStoreRepository());
        expect(await target.restoreBackup(payload), isTrue);
        expect(target.audit.any((e) => e.detail == 'kritik-iade'), isTrue);
        expect(target.audit.any((e) => e.detail == 'kritik-pin'), isTrue);
      } finally {
        await repository.close();
        await directory.delete(recursive: true);
      }
    });
  });

  group('Method-aware refunds', () {
    Pos sellOne(List<PaymentPart> Function(int price) payments, {int openingCash = 1000, bool openRegister = true}) {
      final pos = Pos(repository: MemoryStoreRepository());
      pos.staff.firstWhere((member) => member.name == 'Admin').setPin('8642');
      final product = pos.products.firstWhere((item) => item.price == 500);
      final table = pos.tables.first;
      expect(pos.add(table, product), isTrue);
      expect(pos.sendKitchen(table), isTrue);
      if (openRegister) expect(pos.openRegister(openingCash), isTrue);
      expect(pos.checkout(table, payments(product.price)), isTrue);
      return pos;
    }

    test('cash sale refund leaves the drawer once and nets cash totals', () async {
      final pos = sellOne((price) => [PaymentPart('Nakit', price, tendered: 1000)]);
      final session = pos.activeRegister!;
      expect(pos.expectedRegisterCash(session), 1500);
      expect(pos.refundSale(0, 200, 'Soğuk geldi', '8642'), isTrue);
      expect(pos.expectedRegisterCash(session), 1300);
      expect(pos.cashMovements.single.amount, 200);
      final refund = pos.sales.last;
      expect(refund.payments.single.method, 'Nakit');
      expect(refund.payments.single.amount, -200);
      final netCash = pos.sales.expand((sale) => sale.payments)
          .where((part) => part.method == 'Nakit').fold<int>(0, (a, part) => a + part.amount);
      expect(netCash, 300);
      expect(await pos.integrityCheck(), isEmpty);
    });

    test('card sale refund needs no open register and never touches cash', () async {
      final pos = sellOne((price) => [PaymentPart('Kart', price)], openRegister: false);
      expect(pos.activeRegister, isNull);
      expect(pos.refundSale(0, 500, 'Yanlış sipariş', '8642', returnStock: true), isTrue);
      expect(pos.cashMovements, isEmpty);
      expect(pos.sales.last.registerSessionId, isNull);
      expect(pos.sales.last.payments.single.method, 'Kart');
      final netCard = pos.sales.expand((sale) => sale.payments)
          .where((part) => part.method == 'Kart').fold<int>(0, (a, part) => a + part.amount);
      expect(netCard, 0);
      expect(pos.refundSale(0, 1, 'Tekrar', '8642'), isFalse);
      expect(await pos.integrityCheck(), isEmpty);
    });

    test('split payment refund returns cash first, then card, and survives reload', () async {
      final repository = MemoryStoreRepository();
      final pos = Pos(repository: repository);
      pos.staff.firstWhere((member) => member.name == 'Admin').setPin('8642');
      final product = pos.products.firstWhere((item) => item.price == 500);
      final table = pos.tables.first;
      expect(pos.add(table, product), isTrue);
      expect(pos.sendKitchen(table), isTrue);
      expect(pos.openRegister(1000), isTrue);
      expect(pos.checkout(table, [PaymentPart('Nakit', 200), PaymentPart('Kart', 300)]), isTrue);
      final session = pos.activeRegister!;
      expect(pos.expectedRegisterCash(session), 1200);

      expect(pos.refundSplit(0, 350), (cash: 200, card: 150));
      expect(pos.refundSale(0, 350, 'Kısmi', '8642'), isTrue);
      expect(pos.expectedRegisterCash(session), 1000);
      expect(pos.refundSplit(0, 150), (cash: 0, card: 150));
      expect(pos.refundSale(0, 150, 'Kalan', '8642'), isTrue);
      expect(pos.expectedRegisterCash(session), 1000);
      expect(pos.refundedByMethod(0, 'Nakit'), 200);
      expect(pos.refundedByMethod(0, 'Kart'), 300);
      expect(pos.remainingRefundable(0), 0);
      expect(pos.refundSale(0, 1, 'Mükerrer', '8642'), isFalse);
      await pos.flush();

      final restored = Pos(repository: repository);
      await restored.load();
      expect(restored.refundedByMethod(0, 'Kart'), 300);
      expect(restored.expectedRegisterCash(restored.activeRegister!), 1000);
      expect(await restored.integrityCheck(), isEmpty);
    });

    test('legacy İade refunds count as cash refunds', () {
      final pos = Pos(repository: MemoryStoreRepository());
      pos.sales.add(Sale('2026-11-27', '12:00', 'Admin', 1, 500, 0, [],
          [PaymentPart('Nakit', 300), PaymentPart('Kart', 200)]));
      pos.sales.add(Sale('2026-11-27', '12:30', 'Admin', 1, -100, 0, [],
          [PaymentPart('İade', -100)], isRefund: true, refundOfSaleIndex: 0));
      expect(pos.refundedByMethod(0, 'Nakit'), 100);
      expect(pos.refundSplit(0, 400), (cash: 200, card: 200));
    });
  });

  group('Calendar report periods (Baku business dates)', () {
    test('week starts on Monday and month/year boundaries are exclusive', () {
      // Sunday 30 Nov 2026, 23:59 Baku.
      final sunday = DateTime.utc(2026, 11, 30, 23, 59);
      expect(reportPeriodRange('today', sunday), (start: '2026-11-30', end: '2026-12-01'));
      expect(reportPeriodRange('week', sunday), (start: '2026-11-24', end: '2026-12-01'));
      expect(reportPeriodRange('month', sunday), (start: '2026-11-01', end: '2026-12-01'));
      expect(reportPeriodRange('year', sunday), (start: '2026-01-01', end: '2027-01-01'));
      expect(reportPeriodRange('30', sunday), (start: '2026-11-01', end: '2026-12-01'));
      final december = DateTime.utc(2026, 12, 31, 10);
      expect(reportPeriodRange('month', december), (start: '2026-12-01', end: '2027-01-01'));
      expect(reportPeriodRange('week', DateTime.utc(2026, 12, 1)), (start: '2026-11-30', end: '2026-12-07'));
      final range = reportPeriodRange('month', sunday);
      expect(inReportRange('2026-11-01', range), isTrue);
      expect(inReportRange('2026-11-30', range), isTrue);
      expect(inReportRange('2026-12-01', range), isFalse);
      expect(inReportRange('2026-10-31', range), isFalse);
    });

    test('a sale just after Baku midnight falls on the new business day', () {
      // 20:30 UTC on 30 Nov is 00:30 on 1 Dec in Baku.
      final instant = DateTime.utc(2026, 11, 30, 20, 30);
      final businessDay = dayKey(azWallTime(instant));
      expect(businessDay, '2026-12-01');
      expect(inReportRange(businessDay, reportPeriodRange('month', azWallTime(instant))), isTrue);
      expect(inReportRange(businessDay, reportPeriodRange('month', DateTime.utc(2026, 11, 30, 12))), isFalse);
    });
  });

  group('Reservation status changes', () {
    test('a cancelled reservation cannot be reopened onto a booked slot', () {
      final pos = Pos(repository: MemoryStoreRepository());
      final when = bakuWallTimeToUtc(azWallTime(azNow()).add(const Duration(days: 3)));
      ReservationRecord make(String id) => ReservationRecord(id: id, customerName: 'Müşteri $id',
          phone: '', dateTime: when.toIso8601String(), tableId: 5, guests: 2);
      final first = make('a');
      expect(pos.addReservation(first), isTrue);
      expect(pos.setReservationStatus(first, 'İptal'), isTrue);
      final second = make('b');
      expect(pos.addReservation(second), isTrue);
      expect(pos.setReservationStatus(first, 'Bekliyor'), isFalse);
      expect(first.status, 'İptal');
      expect(pos.setReservationStatus(second, 'İptal'), isTrue);
      expect(pos.setReservationStatus(first, 'Bekliyor'), isTrue);
    });
  });
}
