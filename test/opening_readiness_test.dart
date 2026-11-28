import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/main.dart';
import 'package:restaurant_pos/storage.dart';

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
}
