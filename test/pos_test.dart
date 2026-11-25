import 'package:path/path.dart' as path;
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:restaurant_pos/storage.dart';
import 'package:restaurant_pos/main.dart';
import 'package:restaurant_pos/advanced_features.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class ToggleFailRepository extends MemoryStoreRepository {
  ToggleFailRepository({super.value});
  bool failWrites = false;

  @override
  Future<void> write(String payload) async {
    if (failWrites) throw StateError('Simulated SQLite write failure.');
    await super.write(payload);
  }
}

class FailOnWriteRepository extends MemoryStoreRepository {
  FailOnWriteRepository({super.value});

  int writeCount = 0;
  int? failOnWriteNumber;

  @override
  Future<void> write(String payload) async {
    writeCount++;
    if (writeCount == failOnWriteNumber) {
      value = payload;
      throw StateError('Simulated disk failure after partial replacement.');
    }
    await super.write(payload);
  }
}

void main() {
  test('legacy Baku timestamps migrate once to UTC instants without shifting displayed time', () async {
    final legacy = jsonEncode({
      'products': [],
      'tables': [],
      'sales': [],
      'expenses': [],
      'stockMovements': [
        {'id': 1, 'productId': 'p', 'productName': 'P', 'type': 'Giriş',
          'quantity': 1, 'beforeStock': 0, 'afterStock': 1, 'productCost': 0,
          'at': '2026-11-21T19:00:00.000Z', 'note': 'legacy'},
      ],
      'ingredients': [],
      'recipes': {},
      'registerSessions': [
        {'id': 1, 'openedAt': '2026-11-21T19:00:00.000Z',
          'openingCash': 0, 'closedAt': '2026-11-21T20:00:00.000Z'},
      ],
      'cashMovements': [],
      'staff': [{'name': 'Admin', 'role': 'Yönetici', 'pin': '1234'}],
      'audit': [],
      'advanced': {
        'suppliers': [],
        'purchases': [],
        'customers': [],
        'reservations': [
          {'id': 'r1', 'customerName': 'Test', 'phone': '',
            'dateTime': '2026-11-22T19:00:00', 'tableId': 1,
            'guests': 2, 'note': '', 'status': 'Bekliyor'},
        ],
        'barcodes': {},
      },
    });
    final repository = MemoryStoreRepository(value: legacy);
    final store = Pos(repository: repository);
    await store.load();
    expect(store.recoveryRequired, isFalse);
    expect(store.stockMovements.single.at, '2026-11-21T15:00:00.000Z');
    expect(store.registerSessions.single.openedAt, '2026-11-21T15:00:00.000Z');
    expect(store.registerSessions.single.closedAt, '2026-11-21T16:00:00.000Z');
    expect(bakuTimestamp(store.reservations.single.dateTime), '22.11.2026 19:00');
    final migrated = jsonDecode(repository.value!) as Map<String, dynamic>;
    expect(migrated['timestampFormatVersion'], 2);
    await store.load();
    expect(store.stockMovements.single.at, '2026-11-21T15:00:00.000Z');
  });


  test('Baku wall-time conversion handles midnight and year boundaries', () {
    final newYearWallTime = DateTime.utc(2027, 1, 1, 0, 15);
    final storedInstant = bakuWallTimeToUtc(newYearWallTime);

    expect(storedInstant, DateTime.utc(2026, 12, 31, 20, 15));
    expect(azWallTime(storedInstant), newYearWallTime);
    expect(dayKey(azWallTime(storedInstant)), '2027-01-01');
    expect(bakuTimestamp(storedInstant.toIso8601String()), '01.01.2027 00:15');

    final monthEndWallTime = DateTime.utc(2026, 3, 1, 0, 5);
    expect(bakuWallTimeToUtc(monthEndWallTime), DateTime.utc(2026, 2, 28, 20, 5));
  });

  test('Baku timestamps store UTC instants and display fixed UTC+4 wall time', () {
    final wallTime = DateTime.utc(2026, 11, 21, 19, 30);
    final instant = bakuWallTimeToUtc(wallTime);
    expect(instant, DateTime.utc(2026, 11, 21, 15, 30));
    expect(azWallTime(instant), wallTime);
    expect(bakuTimestamp(instant.toIso8601String()), '21.11.2026 19:30');
    expect(azNow().isUtc, isTrue);
  });


  test('Azerbaijani manat formatting uses qəpik precision', () {
    expect(money(0), '0,00 ₼');
    expect(money(5), '0,05 ₼');
    expect(money(1250), '12,50 ₼');
    expect(money(-1), '-0,01 ₼');
    expect(money(-30), '-0,30 ₼');
    expect(money(-99), '-0,99 ₼');
    expect(money(-100), '-1,00 ₼');
    expect(money(-120), '-1,20 ₼');
    expect(money(-250), '-2,50 ₼');
  });

  test('money parser converts comma decimals to qəpik', () {
    expect(parseMoney('12,50'), 1250);
    expect(parseMoney('3.25'), 325);
    expect(parseMoney('1.234,56'), 123456);
    expect(parseMoney('1,234.56'), 123456);
    expect(parseMoney('1.234'), 123400);
    expect(parseMoney('1 234,56'), 123456);
    expect(parseMoney('invalid'), isNull);
    expect(parseMoney('0'), isNull);
    expect(parseMoney('0', allowZero: true), 0);
    expect(parseMoney('1,2345'), isNull);
  });

  test('stock is reserved across all open tables', () {
    final store = Pos(repository: MemoryStoreRepository());
    final product = Product('test', 'Test', 'Test item', 300, stock: 2);
    store.products = [product];
    expect(store.add(store.tables[0], product), isTrue);
    expect(store.add(store.tables[1], product), isTrue);
    expect(store.add(store.tables[1], product), isFalse);
    expect(store.stockChange(product, -1), isFalse);
  });

  test('kitchen dispatch tracks only sent lines and preserves earlier batches', () {
    final store = Pos(repository: MemoryStoreRepository());
    final product = Product('kitchen-test', 'Test', 'Test item', 300, stock: 5);
    store.products = [product];
    final table = store.tables.first;

    expect(store.add(table, product), isTrue);
    expect(table.items.single.sent, isFalse);
    expect(store.sendKitchen(table), isTrue);
    expect(table.items.single.sent, isTrue);
    store.setKitchen(table, KitchenState.preparing);
    expect(table.items.single.kitchen, KitchenState.preparing);

    expect(store.add(table, product), isTrue);
    expect(table.items, hasLength(2));
    expect(table.items.first.kitchen, KitchenState.preparing);
    expect(table.items.last.sent, isFalse);
    expect(store.sendKitchen(table), isTrue);
    expect(table.items.last.kitchen, KitchenState.queued);
    expect(table.items.first.kitchen, KitchenState.preparing);
    expect(store.qty(table, 0, -1), isFalse);
    expect(store.cancelSentLine(table, table.items.first, 1, 'Müşteri vazgeçti', '1234'), isTrue);
    expect(table.items, hasLength(1));
    expect(table.items.single.sent, isTrue);
    expect(store.reservedStock(product.id), 1);
    expect(store.kitchenNotices.single.productName, product.name);
  });

  test('kitchen dispatch state survives JSON round trip', () {
    final original = OrderLine(
      'p1', 'Tavuk döner', 300, 2,
      sent: true,
      kitchen: KitchenState.preparing,
    );
    final restored = OrderLine.fromJson(original.toJson());
    expect(restored.sent, isTrue);
    expect(restored.kitchen, KitchenState.preparing);
    expect(restored.qty, 2);
  });

  test('legacy order lines migrate as already sent to kitchen', () {
    final restored = OrderLine.fromJson({
      'productId': 'p1',
      'name': 'Tavuk döner',
      'price': 300,
      'qty': 1,
    });
    expect(restored.sent, isTrue);
    expect(restored.kitchen, KitchenState.queued);
  });

  test('cash overpayment records change and checkout consumes stock', () {
    final store = Pos(repository: MemoryStoreRepository());
    final product = Product('test', 'Test', 'Test item', 300, stock: 2);
    store.products = [product];
    final table = store.tables.first;
    expect(store.add(table, product), isTrue);
    expect(store.checkout(table, [PaymentPart('Nakit', 300)]), isFalse);
    expect(store.sendKitchen(table), isTrue);
    final cash = PaymentPart('Nakit', 300, tendered: 500);
    expect(cash.change, 200);
    expect(store.checkout(table, [cash]), isFalse);
    expect(store.openRegister(1000), isTrue);
    expect(store.checkout(table, [cash]), isTrue);
    expect(product.stock, 1);
    expect(table.items, isEmpty);
  });

  test('discount requires reason and respects total', () {
    final store = Pos(repository: MemoryStoreRepository());
    final product = Product('test', 'Test', 'Test item', 1000, stock: 3);
    store.products = [product];
    final table = store.tables.first;
    store.add(table, product);
    expect(store.setDiscount(table, 10, true, ''), isFalse);
    expect(store.setDiscount(table, 10, true, 'Sadakat indirimi'), isTrue);
    expect(table.total, 900);
    expect(store.setDiscount(table, 100, true, 'Tam indirim'), isFalse);
  });

  test('staff PIN is salted and never serialized as plaintext', () {
    final staff = Staff('Test', 'Garson', pin: '5831');
    expect(staff.verifyPin('5831'), isTrue);
    expect(staff.verifyPin('0000'), isFalse);
    expect(staff.toJson().containsKey('pin'), isFalse);
    expect(staff.pinHash, startsWith('pbkdf2-sha256\$120000\$'));
    final restored = Staff.fromJson(staff.toJson());
    expect(restored.verifyPin('5831'), isTrue);
  });

  test('legacy SHA-256 PIN upgrades to PBKDF2 after successful verification', () {
    const salt = 'legacy-salt';
    final legacyHash = sha256.convert(utf8.encode('$salt:2468')).toString();
    final staff = Staff.fromJson({
      'name': 'Legacy', 'role': 'Yönetici', 'salt': salt,
      'pinHash': legacyHash, 'pinRequired': true, 'active': true,
    });
    expect(staff.verifyPin('2468'), isTrue);
    expect(staff.pinHash, startsWith('pbkdf2-sha256\$120000\$'));
    expect(staff.verifyPin('0000'), isFalse);
  });

  test('administrator PIN lockout persists across application reloads', () async {
    final repository = MemoryStoreRepository();
    final store = Pos(repository: repository);
    store.staff.first.setPin('2468');
    store.save();
    await store.flush();
    for (var attempt = 0; attempt < 5; attempt++) {
      expect(store.verifyAdminPin('0000'), isFalse);
    }
    expect(store.pinLockRemainingForStaff(store.staff.first), greaterThan(0));
    await store.flush();
    final restored = Pos(repository: repository);
    await restored.load();
    expect(restored.pinLockRemainingForStaff(restored.staff.first), greaterThan(0));
    expect(restored.verifyAdminPin('2468'), isFalse);
  });

  test('staff PIN failures use a separate persistent lockout scope', () async {
    final repository = MemoryStoreRepository();
    final store = Pos(repository: repository);
    expect(store.addStaff('Aysel', 'Mutfak', '7391'), isTrue);
    final member = store.staff.singleWhere((entry) => entry.name == 'Aysel');
    for (var attempt = 0; attempt < 5; attempt++) {
      expect(store.loginAsStaff(member, pin: '0000'), isFalse);
    }
    expect(store.pinLockRemainingForStaff(member), greaterThan(0));
    await store.flush();
    final restored = Pos(repository: repository);
    await restored.load();
    final restoredMember = restored.staff.singleWhere((entry) => entry.name == 'Aysel');
    expect(restored.pinLockRemainingForStaff(restoredMember), greaterThan(0));
    expect(restored.loginAsStaff(restoredMember, pin: '7391'), isFalse);
  });

  test('supervisor PIN validation is throttled after repeated failures', () {
    final store = Pos(repository: MemoryStoreRepository());
    for (var attempt = 0; attempt < 5; attempt++) {
      expect(store.verifySupervisorPin('0000'), isFalse);
    }
    expect(store.pinLockRemainingForStaff(store.staff.first), greaterThan(0));
    expect(store.verifySupervisorPin('1234'), isFalse);
  });

  test('PIN lockout state persists in SQLite app_meta', () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp('pos-pin-security-');
    final repository = SqliteStoreRepository(
      databasePath: '${directory.path}/restaurant-pos.sqlite3',
      backupDirectoryPath: '${directory.path}/backups',
    );
    try {
      final store = Pos(repository: repository);
      store.staff.first.setPin('2468');
      store.save();
      await store.flush();
      for (var attempt = 0; attempt < 5; attempt++) {
        expect(store.verifyAdminPin('0000'), isFalse);
      }
      await store.flush();
      final restored = Pos(repository: repository);
      await restored.load();
      expect(restored.pinLockRemainingForStaff(restored.staff.first), greaterThan(0));
      expect(restored.verifyAdminPin('2468'), isFalse);
    } finally {
      await repository.close();
      await directory.delete(recursive: true);
    }
  });

  test('PIN lockout escalates from 30 seconds to 60 seconds', () {
    final store = Pos(repository: MemoryStoreRepository());
    store.pinSecurity['staff:Admin'] = {'failedAttempts': 0, 'lockouts': 1};
    for (var attempt = 0; attempt < 5; attempt++) {
      expect(store.verifyAdminPin('0000'), isFalse);
    }
    expect(store.pinLockRemainingForStaff(store.staff.first), greaterThan(30));
  });

  test('only the administrator account can access POS actions', () {
    final store = Pos(repository: MemoryStoreRepository());
    store.currentUser = 'Garson';
    expect(store.can('orders'), isFalse);
    expect(store.can('kitchen'), isFalse);
    expect(store.can('inventory'), isFalse);
    expect(store.can('discount'), isFalse);
    expect(store.can('reports'), isFalse);
  });

  test('legacy administrator is reactivated during migration', () async {
    final repository = MemoryStoreRepository(value: '{"products":[],"tables":[],"sales":[],"staff":[{"name":"Admin","role":"Yönetici","pin":"2468","active":false}],"audit":[]}');
    final store = Pos(repository: repository);
    await store.load();
    expect(store.staff.single.name, 'Admin');
    expect(store.staff.single.active, isTrue);
    expect(store.can('reports'), isTrue);
  });

  test('backup restore preserves the current state before replacing it', () async {
    final repository = MemoryStoreRepository(value: '{"products":[{"id":"old","category":"Test","name":"Old","price":100,"stock":5,"lowAt":1,"active":true}],"tables":[],"sales":[],"staff":[{"name":"Admin","role":"Yönetici","pin":"8642","active":true}],"audit":[]}');
    final store = Pos(repository: repository);
    await store.load();
    const backup = '{"products":[{"id":"new","category":"Test","name":"Restored","price":250,"stock":8,"lowAt":2,"active":true}],"tables":[],"sales":[],"staff":[{"name":"Admin","role":"Yönetici","pin":"2468","active":true}],"audit":[]}';

    expect(await store.restoreBackup(backup), isTrue);
    expect(store.products.single.name, 'Restored');
    expect(repository.backupFiles, hasLength(1));
    expect(repository.backupFiles.values.single, contains('"Old"'));
  });

  test('failed backup replacement rolls the previous POS state back', () async {
    final repository = FailOnWriteRepository(
      value: '{"products":[{"id":"old","category":"Test","name":"Old","price":100,"stock":5,"lowAt":1,"active":true}],"tables":[],"sales":[],"staff":[{"name":"Admin","role":"Yönetici","pin":"8642","active":true}],"audit":[]}',
    );
    final store = Pos(repository: repository);
    await store.load();
    // Loading this legacy fixture may perform its one-time migration write.
    // Arm the simulated partial-write failure only after the initial load.
    repository.failOnWriteNumber = repository.writeCount + 1;
    const backup = '{"products":[{"id":"new","category":"Test","name":"Restored","price":250,"stock":8,"lowAt":2,"active":true}],"tables":[],"sales":[],"staff":[{"name":"Admin","role":"Yönetici","pin":"2468","active":true}],"audit":[]}';

    expect(await store.restoreBackup(backup), isFalse);
    expect(store.recoveryRequired, isFalse);
    expect(store.products.single.name, 'Old');
    expect(repository.value, contains('"Old"'));
    expect(repository.value, isNot(contains('"Restored"')));
    expect(repository.backupFiles, hasLength(1));
  });

  test('failed final restore persistence rolls back the previous POS state', () async {
    final repository = FailOnWriteRepository(
      value: '{"products":[{"id":"old","category":"Test","name":"Old","price":100,"stock":5,"lowAt":1,"active":true}],"tables":[],"sales":[],"staff":[{"name":"Admin","role":"Yönetici","pin":"8642","active":true}],"audit":[]}',
    );
    final store = Pos(repository: repository);
    await store.load();
    repository.failOnWriteNumber = repository.writeCount + 2;
    const backup = '{"products":[{"id":"new","category":"Test","name":"Restored","price":250,"stock":8,"lowAt":2,"active":true}],"tables":[],"sales":[],"staff":[{"name":"Admin","role":"Yönetici","pin":"2468","active":true}],"audit":[]}';

    expect(await store.restoreBackup(backup), isFalse);
    expect(store.recoveryRequired, isFalse);
    expect(store.products.single.name, 'Old');
    expect(repository.value, contains('"Old"'));
    expect(repository.value, isNot(contains('"Restored"')));
    expect(repository.backupFiles, hasLength(1));
  });

  test('malformed nested legacy backup cannot replace current data', () async {
    final repository = MemoryStoreRepository(
      value: '{"products":[{"id":"old","category":"Test","name":"Old","price":100,"stock":5,"lowAt":1,"active":true}],"tables":[],"sales":[],"staff":[{"name":"Admin","role":"Yönetici","pin":"8642","active":true}],"audit":[]}',
    );
    final store = Pos(repository: repository);
    await store.load();
    const malformedLegacyBackup = '{"products":[{"id":"new","category":"Test","name":"Broken","price":100,"stock":5,"lowAt":1,"active":true}],"tables":[{"id":1,"items":[null]}],"sales":[],"staff":[{"name":"Admin","role":"Yönetici","pin":"2468","active":true}],"audit":[]}';

    expect(await store.restoreBackup(malformedLegacyBackup), isFalse);
    expect(store.products.single.name, 'Old');
    expect(repository.value, contains('"Old"'));
    expect(repository.value, isNot(contains('"Broken"')));
    expect(repository.backupFiles, isEmpty);
  });

  test('SQLite transaction failure during backup replacement preserves the previous database', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp('pos-sqlite-restore-failure-');
    final databasePath = '${directory.path}/restaurant-pos.sqlite3';
    final repository = SqliteStoreRepository(
      databasePath: databasePath,
      backupDirectoryPath: directory.path,
    );
    try {
      final store = Pos(repository: repository);
      await store.load();
      store.products.first.name = 'Original';
      store.save();
      await store.flush();

      // Reopen the repository after installing the trigger so its SQLite
      // connection refreshes the schema before the restore transaction.
      await repository.close();
      final triggerDatabase = await openDatabase(databasePath);
      try {
        // Every normalized SQLite write begins by inserting app_meta rows.
        // Fail that first write, rather than depending on a DELETE that can
        // legitimately affect zero rows and therefore never invoke a trigger.
        await triggerDatabase.execute("""
          CREATE TRIGGER reject_restore_meta_insert
          BEFORE INSERT ON app_meta
          BEGIN
            SELECT RAISE(ABORT, 'Simulated SQLite restore write failure');
          END;
        """);
        final triggerRows = await triggerDatabase.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name = 'reject_restore_meta_insert'");
        expect(triggerRows, hasLength(1));

        // Prove the exact operation used by StoreRepository.write is rejected.
        await expectLater(
          triggerDatabase.insert('app_meta', {
            'key': 'restore_failure_probe',
            'value': 'must-not-be-written',
          }),
          throwsA(isA<DatabaseException>()),
        );
        final probeRows = await triggerDatabase.query(
          'app_meta',
          where: 'key = ?',
          whereArgs: ['restore_failure_probe'],
        );
        expect(probeRows, isEmpty);

        // Keep the schema-owning connection open while the repository opens
        // its own connection for restore. This avoids closing/reopening the
        // only connection that installed the fault injector before it is used.
        const backup = '{"products":[{"id":"restored","category":"Test","name":"Restored","price":250,"costPrice":0,"stock":8,"lowAt":2,"active":true}],"tables":[],"sales":[],"staff":[{"name":"Admin","role":"Yönetici","pin":"2468","active":true}],"audit":[]}';
        expect(await store.restoreBackup(backup), isFalse);
        expect(store.recoveryRequired, isFalse);
        expect(store.products.first.name, 'Original');

        final reloaded = Pos(repository: repository);
        await reloaded.load();
        expect(reloaded.recoveryRequired, isFalse);
        expect(reloaded.products.first.name, 'Original');
        expect(await reloaded.integrityCheck(), isEmpty);
      } finally {
        await triggerDatabase.close();
      }
    } finally {
      await repository.close();
      await directory.delete(recursive: true);
    }
  });

  test('invalid backup cannot replace current data', () async {
    final repository = MemoryStoreRepository(value: '{"products":[{"id":"old","category":"Test","name":"Old","price":100,"stock":5,"lowAt":1,"active":true}],"tables":[],"sales":[],"staff":[],"audit":[]}');
    final store = Pos(repository: repository);
    await store.load();

    expect(await store.restoreBackup('{broken-json'), isFalse);
    expect(store.products.single.name, 'Old');
    expect(repository.backupFiles, isEmpty);
  });

  test('backup without an explicit administrator credential is rejected', () async {
    final repository = MemoryStoreRepository(value: '{"products":[],"tables":[],"sales":[],"staff":[{"name":"Admin","role":"Yönetici","pin":"8642","active":true}],"audit":[]}');
    final store = Pos(repository: repository);
    await store.load();
    const backup = '{"products":[],"tables":[],"sales":[],"staff":[],"audit":[]}';
    expect(await store.restoreBackup(backup), isFalse);
    expect(repository.backupFiles, isEmpty);
    expect(store.staff.single.verifyPin('8642'), isTrue);
  });

  test('manual and corrupt backup names are restorable but not daily backups', () {
    expect(isRestorableBackupFileName('restaurant-pos-manual-2026-11-21T12-30-00.json'), isTrue);
    expect(isRestorableBackupFileName('restaurant-pos-corrupt-2026-11-21T12-30-00.json'), isTrue);
    expect(isRestorableBackupFileName('../restaurant-pos-manual-2026-11-21.json'), isFalse);
    expect(isRestorableBackupFileName('restaurant-pos-manual-not-json.txt'), isFalse);
  });
  test('SQLite persists kitchen cancellation notice and cancelled amount', () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp('pos-kitchen-notice-');
    final repository = SqliteStoreRepository(
      databasePath: '${directory.path}/restaurant-pos.sqlite3',
      backupDirectoryPath: directory.path,
    );
    try {
      final store = Pos(repository: repository);
      final table = store.tables.first;
      final product = store.products.first;
      expect(store.add(table, product), isTrue);
      expect(store.sendKitchen(table), isTrue);
      expect(store.cancelSentLine(table, table.items.single, 1, 'Müşteri vazgeçti', '1234'), isTrue);
      await store.flush();

      final restored = Pos(repository: repository);
      await restored.load();
      expect(restored.kitchenNotices, hasLength(1));
      expect(restored.kitchenNotices.single.productName, product.name);
      expect(restored.kitchenNotices.single.quantity, 1);
      expect(restored.kitchenNotices.single.amount, product.price);
      expect(restored.audit.first.detail, contains(money(product.price)));
    } finally {
      await repository.close();
      await directory.delete(recursive: true);
    }
  });

  test('manual backup export is repository-backed, atomic and immediately discoverable', () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp('pos-manual-backup-');
    final repository = SqliteStoreRepository(
      databasePath: '${directory.path}/restaurant-pos.sqlite3',
      backupDirectoryPath: directory.path,
    );
    try {
      final store = Pos(repository: repository);
      await store.load();
      store.products.first.name = 'Exported product';
      final exportedPath = await store.exportBackup();
      final exportedFile = File(exportedPath);
      expect(await exportedFile.exists(), isTrue);
      final payload = await exportedFile.readAsString();
      expect(payload, contains('Exported product'));
      final backups = await store.listBackups();
      expect(backups.map((backup) => backup.name), contains(path.basename(exportedPath)));
      expect(await store.readBackup(path.basename(exportedPath)), payload);
      final backupDirectory = Directory('${directory.path}/backups');
      expect(await backupDirectory.list().where((entry) => entry.path.endsWith('.tmp')).isEmpty, isTrue);
    } finally {
      await repository.close();
      await directory.delete(recursive: true);
    }
  });

  test('backup retention matches only dated daily JSON files', () {
    expect(isDailyBackupFileName('restaurant-pos-2026-11-19.json'), isTrue);
    expect(isDailyBackupFileName('restaurant-pos-corrupt-2026-11-19T12-00-00.json'), isFalse);
    expect(isDailyBackupFileName('restaurant-pos-not-a-date.json'), isFalse);
  });

  test('unknown and inactive users receive no permissions', () {
    final store = Pos(repository: MemoryStoreRepository());
    store.currentUser = 'unknown';
    expect(store.can('orders'), isFalse);
    store.currentUser = 'Admin';
    store.staff.firstWhere((member) => member.name == 'Admin').active = false;
    expect(store.can('reports'), isFalse);
  });

  test('removing the last order line clears discount and kitchen state', () {
    final store = Pos(repository: MemoryStoreRepository());
    final table = store.tables.first;
    table.items.add(OrderLine('p1', 'Tavuk döner', 300, 1));
    table.discount = 100;
    table.discountReason = 'Test';
    table.kitchen = KitchenState.ready;

    expect(store.qty(table, 0, -1), isTrue);
    expect(table.items, isEmpty);
    expect(table.discount, 0);
    expect(table.discountReason, isEmpty);
    expect(table.kitchen, KitchenState.queued);
  });

  test('product edits preserve inactive state and reject stock below reservations', () {
    final store = Pos(repository: MemoryStoreRepository());
    final original = store.products.first;
    original.active = false;
    store.upsertProduct(Product(original.id, original.category, original.name,
        original.price, stock: original.stock, active: true));
    expect(store.products.firstWhere((p) => p.id == original.id).active, isFalse);

    final table = store.tables.first;
    table.items.add(OrderLine(original.id, original.name, original.price, 3));
    final previousStock = store.products.firstWhere((p) => p.id == original.id).stock;
    store.upsertProduct(Product(original.id, original.category, original.name,
        original.price, stock: 2));
    expect(store.products.firstWhere((p) => p.id == original.id).stock,
        previousStock);
  });

  test('corrupt local data enters read-only recovery without replacing data', () async {
    final repository = MemoryStoreRepository(value: '{broken-json');
    final store = Pos(repository: repository);
    await store.load();
    expect(repository.corruptBackup, '{broken-json');
    expect(repository.value, '{broken-json');
    expect(store.recoveryRequired, isTrue);
    store.save();
    await store.flush();
    expect(repository.value, '{broken-json');
  });

  test('manual and corrupt backups are discoverable for recovery', () {
    expect(isRestorableBackupFileName('restaurant-pos-manual-2026-11-21T12-00-00.json'), isTrue);
    expect(isRestorableBackupFileName('restaurant-pos-corrupt-2026-11-21T12-00-00.json'), isTrue);
  });


  test('money parser rejects non-finite values', () {
    expect(parseMoney('NaN'), isNull);
    expect(parseMoney('Infinity'), isNull);
  });
  test('cash and mixed payments require an open register while card-only does not', () {
    final store = Pos(repository: MemoryStoreRepository());
    final product = Product('register-guard', 'Test', 'Test item', 300, stock: 5);
    store.products = [product];

    final cashTable = store.tables[0];
    expect(store.add(cashTable, product), isTrue);
    expect(store.sendKitchen(cashTable), isTrue);
    expect(store.checkout(cashTable, [PaymentPart('Nakit', 300)]), isFalse);
    expect(cashTable.items, hasLength(1));

    final mixedTable = store.tables[1];
    expect(store.add(mixedTable, product), isTrue);
    expect(store.sendKitchen(mixedTable), isTrue);
    expect(store.checkout(mixedTable, [
      PaymentPart('Nakit', 100),
      PaymentPart('Kart', 200),
    ]), isFalse);
    expect(mixedTable.items, hasLength(1));

    expect(store.checkout(cashTable, [PaymentPart('Kart', 300)]), isTrue);
    expect(store.sales.single.registerSessionId, isNull);
  });

  test('checkout rejects invalid tender and unsupported payment methods', () {
    final store = Pos(repository: MemoryStoreRepository());
    final product = Product('pay-test', 'Test', 'Test item', 300, stock: 2);
    store.products = [product];
    final table = store.tables.first;
    expect(store.add(table, product), isTrue);
    expect(store.sendKitchen(table), isTrue);
    expect(store.checkout(table, [PaymentPart('Nakit', 300, tendered: 200)]), isFalse);
    expect(store.checkout(table, [PaymentPart('Bitcoin', 300)]), isFalse);
    expect(store.checkout(table, [PaymentPart('Kart', 300, tendered: 300)]), isTrue);
  });


  test('SQLite persists normalized POS tables and reconstructs the full state', () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp('restaurant-pos-sqlite-');
    final repository = SqliteStoreRepository(
      databasePath: '${directory.path}/pos.sqlite3',
      backupDirectoryPath: directory.path,
    );
    final payload = {
      'products': [
        {'id': 'p1', 'category': 'Dönerler', 'name': 'Tavuk döner',
          'price': 350, 'costPrice': 0, 'stock': 12, 'lowAt': 3, 'active': true},
      ],
      'tables': [
        {'id': 1, 'kitchen': 1, 'discount': 50, 'discountPercent': false,
          'discountReason': 'Sadakat', 'items': [
            {'productId': 'p1', 'name': 'Tavuk döner', 'price': 350,
              'qty': 2, 'sent': true, 'kitchen': 1},
            {'productId': 'p1', 'name': 'Tavuk döner', 'price': 350,
              'qty': 1, 'sent': false, 'kitchen': 0},
          ]},
      ],
      'sales': [
        {'date': '2026-11-19', 'time': '12:30', 'staff': 'Admin',
          'table': 1, 'total': 650, 'discount': 50, 'discountReason': 'Sadakat',
          'discountPercent': true, 'registerSessionId': 123,
          'isRefund': false, 'refundOfSaleIndex': null, 'reason': '',
          'stockReturned': false, 'ingredientUsage': null,
          'items': [
            {'productId': 'p1', 'name': 'Tavuk döner', 'price': 350,
              'qty': 2, 'unitCost': 0, 'sent': true, 'kitchen': 3},
          ],
          'payments': [
            {'method': 'Nakit', 'amount': 650, 'tendered': 700},
            {'method': 'Kart', 'amount': 0, 'tendered': 0},
          ]},
      ],
      'registerSessions': [
        {'id': 123, 'openedAt': '2026-11-19T08:00:00.000',
          'closedAt': null, 'openingCash': 1000, 'closingCash': null,
          'expectedCash': null, 'note': 'Səhər növbəsi'},
      ],
      'cashMovements': [
        {'id': 456, 'sessionId': 123, 'at': '2026-11-19T09:00:00.000',
          'type': 'Giriş', 'amount': 250, 'note': 'Xırda pul'},
      ],
      'staff': [
        {'name': 'Admin', 'role': 'Yönetici', 'salt': 'salt-value',
          'pinHash': 'hashed-pin', 'active': true},
      ],
      'audit': [
        {'at': '19.11.2026 12:00', 'user': 'Admin',
          'action': 'Test', 'detail': 'İlk kayıt'},
        {'at': '19.11.2026 12:01', 'user': 'Admin',
          'action': 'Test 2', 'detail': 'İkinci kayıt'},
      ],
      'currentUser': 'Admin',
    };

    try {
      await repository.write(jsonEncode(payload));
      final restored = jsonDecode((await repository.read())!) as Map<String, dynamic>;
      expect(restored['products'], payload['products']);
      expect(restored['tables'], payload['tables']);
      expect(restored['sales'], payload['sales']);
      final restoredSale = (restored['sales'] as List).single as Map<String, dynamic>;
      expect(restoredSale['discountReason'], 'Sadakat');
      expect(restoredSale['discountPercent'], isTrue);
      expect(restored['registerSessions'], payload['registerSessions']);
      expect(restored['cashMovements'], payload['cashMovements']);
      expect(restored['staff'], payload['staff']);
      expect(restored['audit'], payload['audit']);
      expect(restored['currentUser'], 'Admin');
    } finally {
      await repository.close();
      await directory.delete(recursive: true);
    }
  });

  test('sale discount reason and percentage survive model serialization', () {
    final sale = Sale('2026-11-22', '12:00', 'Admin', 1, 900, 100, [],
      [PaymentPart('Kart', 900)], discountReason: 'Sadakat indirimi', discountPercent: true);
    final restored = Sale.fromJson(Map<String, dynamic>.from(jsonDecode(jsonEncode(sale.toJson()))));
    expect(restored.discountReason, 'Sadakat indirimi');
    expect(restored.discountPercent, isTrue);
    expect(restored.discount, 100);
  });

  test('SQLite v4 sales table migrates discount and refund audit fields to schema v6', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final directory = await Directory.systemTemp.createTemp('restaurant-pos-v4-');
    final databasePath = '${directory.path}/pos.sqlite3';
    final oldDatabase = await openDatabase(databasePath, version: 4, onCreate: (db, version) async {
      await db.execute("CREATE TABLE sales (position INTEGER PRIMARY KEY, date TEXT NOT NULL, time TEXT NOT NULL, staff TEXT NOT NULL, table_id INTEGER NOT NULL, total INTEGER NOT NULL, discount INTEGER NOT NULL, register_session_id INTEGER)");
    });
    await oldDatabase.close();
    final repository = SqliteStoreRepository(databasePath: databasePath, backupDirectoryPath: directory.path);
    try {
      // read() opens and upgrades the v4 database before later schema reads fail
      // because this fixture intentionally contains only the legacy sales table.
      await expectLater(repository.read(), throwsA(anything));
      await repository.close();
      final migrated = await openDatabase(databasePath, readOnly: true);
      try {
        final columns = await migrated.rawQuery('PRAGMA table_info(sales)');
        expect(columns.any((column) => column['name'] == 'discount_reason'), isTrue);
        expect(columns.any((column) => column['name'] == 'discount_percent'), isTrue);
        expect(columns.any((column) => column['name'] == 'is_refund'), isTrue);
        expect(columns.any((column) => column['name'] == 'refund_of_sale_index'), isTrue);
        expect(columns.any((column) => column['name'] == 'reason'), isTrue);
        expect(columns.any((column) => column['name'] == 'stock_returned'), isTrue);
        expect(columns.any((column) => column['name'] == 'ingredient_usage'), isTrue);
        final orderLineColumns = await migrated.rawQuery('PRAGMA table_info(order_lines)');
        expect(orderLineColumns.any((column) => column['name'] == 'ingredient_usage'), isTrue);
      } finally {
        await migrated.close();
      }
    } finally {
      await repository.close();
      await directory.delete(recursive: true);
    }
  });

  test('legacy SharedPreferences payload is read without premature migration', () async {
    SharedPreferences.setMockInitialValues({
      legacyStoreKey: '{"products":[],"tables":[],"sales":[],"staff":[],"audit":[]}',
    });
    final directory = await Directory.systemTemp.createTemp('restaurant-pos-legacy-');
    final repository = SqliteStoreRepository(
      databasePath: '${directory.path}/pos.sqlite3',
      backupDirectoryPath: directory.path,
    );
    try {
      expect(await repository.read(),
          '{"products":[],"tables":[],"sales":[],"staff":[],"audit":[]}');
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString(legacyStoreKey), isNotNull);
    } finally {
      await repository.close();
      await directory.delete(recursive: true);
    }
  });

  test('cash register reconciles opening float, sales and cash movements', () {
    final store = Pos(repository: MemoryStoreRepository());
    expect(store.openRegister(10000), isTrue);
    final session = store.activeRegister!;
    expect(store.openRegister(5000), isFalse);

    final product = Product('register-test', 'Test', 'Test item', 300, stock: 3);
    store.products = [product];
    final table = store.tables.first;
    expect(store.add(table, product), isTrue);
    expect(store.sendKitchen(table), isTrue);
    expect(store.checkout(table, [PaymentPart('Nakit', 300)]), isTrue);
    expect(store.sales.single.registerSessionId, session.id);

    expect(store.addCashMovement('Giriş', 5000, 'Xırda pul'), isTrue);
    expect(store.addCashMovement('Çıxış', 2000, 'Təchizat'), isTrue);
    expect(store.expectedRegisterCash(session), 13300);
    expect(store.addCashMovement('Çıxış', 20000, 'Həddən artıq'), isFalse);

    expect(store.closeRegister(13000), isTrue);
    expect(store.activeRegister, isNull);
    expect(session.expectedCash, 13300);
    expect(session.closingCash, 13000);
    expect(store.openRegister(5000), isTrue);
  });

  test('cash register and movement records survive POS JSON snapshot restore', () async {
    final repository = MemoryStoreRepository();
    final store = Pos(repository: repository);
    expect(store.openRegister(7500, note: 'Gündüz'), isTrue);
    expect(store.addCashMovement('Giriş', 1200, 'Xırda pul'), isTrue);
    await store.flush();

    final restored = Pos(repository: MemoryStoreRepository(value: repository.value));
    await restored.load();
    expect(restored.registerSessions, hasLength(1));
    expect(restored.registerSessions.single.openingCash, 7500);
    expect(restored.cashMovements, hasLength(1));
    expect(restored.cashMovements.single.amount, 1200);
    expect(restored.expectedRegisterCash(restored.activeRegister!), 8700);
  });


  test('corrupt recipe data enters recovery and preserves the original payload', () async {
    final ingredient = Ingredient(id: 'partial', name: 'Un', unit: 'kg',
      stock: 10, lowAt: 2, costPerUnit: 150);
    final raw = jsonEncode({
      'products': [],
      'ingredients': [ingredient.toJson()],
      'recipes': {'product-1': ['invalid recipe line']},
    });
    final repository = MemoryStoreRepository(value: raw);
    final store = Pos(repository: repository);

    await store.load();

    expect(store.recoveryRequired, isTrue);
    expect(store.ingredients, hasLength(1));
    expect(store.ingredients.single.id, 'partial');
    expect(store.recipes, isEmpty);
    store.save();
    await store.flush();
    expect(repository.value, raw);
  });

  test('version 2 SQLite database upgrades without losing its legacy payload', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp('restaurant-pos-v2-');
    final databasePath = '${directory.path}/pos.sqlite3';
    const legacy = '{"products":[],"tables":[],"sales":[],"staff":[],"audit":[]}';
    final oldDatabase = await openDatabase(
      databasePath,
      version: 2,
      onCreate: (db, version) async {
        await db.execute('CREATE TABLE app_state (id INTEGER PRIMARY KEY CHECK (id = 1), payload TEXT NOT NULL, updated_at TEXT NOT NULL)');
        await db.insert('app_state', {
          'id': 1, 'payload': legacy, 'updated_at': '2026-11-18T00:00:00.000',
        });
        await db.execute('CREATE TABLE sales (position INTEGER PRIMARY KEY, date TEXT NOT NULL, time TEXT NOT NULL, staff TEXT NOT NULL, table_id INTEGER NOT NULL, total INTEGER NOT NULL, discount INTEGER NOT NULL)');
      },
    );
    await oldDatabase.close();
    final repository = SqliteStoreRepository(
      databasePath: databasePath,
      backupDirectoryPath: directory.path,
    );
    try {
      expect(await repository.read(), legacy);
      await repository.write(legacy);
      expect(jsonDecode((await repository.read())!)['products'], isEmpty);
    } finally {
      await repository.close();
      await directory.delete(recursive: true);
    }
  });



  test('sale captures product cost and calculates gross profit',(){final store=Pos(repository:MemoryStoreRepository());final p=Product('cost','Test','Item',1000,costPrice:400,stock:2);store.products=[p];final table=store.tables.first;expect(store.add(table,p),isTrue);expect(store.sendKitchen(table),isTrue);expect(store.checkout(table,[PaymentPart('Kart',1000)]),isTrue);p.costPrice=800;expect(store.costOfSale(store.sales.single),400);expect(store.netProfit,600);});
  test('expense and stock ledger survive serialization',()async{final repo=MemoryStoreRepository();final store=Pos(repository:repo);final p=Product('ledger','Test','Item',500,costPrice:200,stock:5);store.products=[p];expect(store.stockChange(p,2,note:'Alım'),isTrue);expect(store.addExpense(2500,'Elektrik','Fatura'),isTrue);await store.flush();final copy=Pos(repository:MemoryStoreRepository(value:repo.value));await copy.load();expect(copy.expenses.single.amount,2500);expect(copy.stockMovements.single.afterStock,7);expect(copy.products.single.costPrice,200);expect(copy.buildCsv(),contains('Elektrik'));});

  test('checkout validates seller and aggregate stock before changing inventory', () {
    final store = Pos(repository: MemoryStoreRepository());
    final product = Product('atomic-checkout', 'Test', 'Test item', 300, stock: 1);
    store.products = [product];
    final table = store.tables.first;
    table.items.add(OrderLine(product.id, product.name, product.price, 1, sent: true));
    table.items.add(OrderLine(product.id, product.name, product.price, 1, sent: true));

    expect(store.checkout(table, [PaymentPart('Kart', 600)], staffName: 'Admin'), isFalse);
    expect(product.stock, 1);
    expect(store.sales, isEmpty);
    expect(store.stockMovements, isEmpty);

    table.items.removeLast();
    expect(store.checkout(table, [PaymentPart('Kart', 300)], staffName: '   '), isFalse);
    expect(product.stock, 1);
    expect(store.sales, isEmpty);
    expect(store.stockMovements, isEmpty);
  });

  test('stock ledger records the actual clamped inventory change', () {
    final store = Pos(repository: MemoryStoreRepository());
    final product = store.products.first;

    product.stock = 999999;
    expect(store.stockChange(product, 100, note: 'Üst sınır testi'), isTrue);
    expect(product.stock, 1000000);
    expect(store.stockMovements.last.type, 'Giriş');
    expect(store.stockMovements.last.quantity, 1);
    expect(store.stockMovements.last.beforeStock, 999999);
    expect(store.stockMovements.last.afterStock, 1000000);

    product.stock = 1;
    expect(store.stockChange(product, -100, note: 'Alt sınır testi'), isTrue);
    expect(product.stock, 0);
    expect(store.stockMovements.last.type, 'Çıkış');
    expect(store.stockMovements.last.quantity, 1);
    expect(store.stockMovements.last.beforeStock, 1);
    expect(store.stockMovements.last.afterStock, 0);
  });

  test('CSV export header contains a real line break', () {
    final store = Pos(repository: MemoryStoreRepository());
    final csv = store.buildCsv();
    expect(csv, startsWith('Tarih;Tür;Açıklama;Adet;Ciro/Gider;Maliyet\r\n'));
    expect(csv, isNot(contains(r'\r\n')));
  });

  test('PIN-free waiter login grants order entry only', () {
    final store = Pos(repository: MemoryStoreRepository());
    final product = Product('waiter-test', 'Test', 'Test item', 300, stock: 3);
    store.products = [product];

    expect(store.addStaff('Ayşe', 'Garson', null), isTrue);
    final waiter = store.staff.singleWhere((member) => member.name == 'Ayşe');
    expect(waiter.pinRequired, isFalse);
    expect(waiter.verifyPin('1234'), isFalse);

    expect(store.loginAsWaiter(waiter), isTrue);
    expect(store.currentUser, 'Ayşe');
    expect(store.can('orders'), isTrue);
    for (final permission in ['inventory', 'reports', 'register', 'kitchen',
      'discount', 'staff', 'table_manage']) {
      expect(store.can(permission), isFalse, reason: 'Waiter must not access $permission');
    }

    final table = store.tables.first;
    expect(store.add(table, product), isTrue);
    expect(store.sendKitchen(table), isTrue);
    expect(store.moveTable(table, store.tables[1]), isFalse);
    expect(store.checkout(table, [PaymentPart('Nakit', 300)]), isFalse);
  });

  test('cashier login grants order and register access only', () {
    final store = Pos(repository: MemoryStoreRepository());
    expect(store.addStaff('Mehmet', 'Kasiyer', '4826'), isTrue);
    final cashier = store.staff.singleWhere((member) => member.name == 'Mehmet');

    expect(store.loginAsStaff(cashier, pin: '0000'), isFalse);
    expect(store.loginAsStaff(cashier, pin: '4826'), isTrue);
    expect(store.isCashier, isTrue);
    expect(store.can('orders'), isTrue);
    expect(store.can('register'), isTrue);
    for (final permission in ['inventory', 'reports', 'kitchen',
      'discount', 'staff', 'table_manage']) {
      expect(store.can(permission), isFalse,
        reason: 'Cashier must not access $permission');
    }
  });

  test('kitchen login grants kitchen status access only', () {
    final store = Pos(repository: MemoryStoreRepository());
    expect(store.addStaff('Aysel', 'Mutfak', '7391'), isTrue);
    final kitchen = store.staff.singleWhere((member) => member.name == 'Aysel');

    expect(store.loginAsStaff(kitchen, pin: '7391'), isTrue);
    expect(store.isKitchenStaff, isTrue);
    expect(store.can('kitchen'), isTrue);
    for (final permission in ['orders', 'inventory', 'reports', 'register',
      'discount', 'staff', 'table_manage']) {
      expect(store.can(permission), isFalse,
        reason: 'Kitchen staff must not access $permission');
    }
    final product = store.products.first;
    final table = store.tables.first;
    table.items.add(OrderLine(product.id, product.name, product.price, 1, sent: true));
    expect(store.setKitchenLine(table, table.items.single, KitchenState.preparing), isTrue);
    expect(store.checkout(table, [PaymentPart('Nakit', product.price)]), isFalse);
  });

  test('unknown staff roles cannot create a signed-in session', () {
    final store = Pos(repository: MemoryStoreRepository());
    final unknown = Staff('Bilinmeyen', 'Yetkisiz', pin: '5791');
    store.staff.add(unknown);
    expect(store.loginAsStaff(unknown, pin: '5791'), isFalse);
    expect(store.currentUser, 'Admin');
  });

  test('inactive staff cannot log in', () {
    final store = Pos(repository: MemoryStoreRepository());
    expect(store.addStaff('Pasif', 'Kasiyer', '2468'), isTrue);
    final cashier = store.staff.singleWhere((member) => member.name == 'Pasif');
    expect(store.setStaffActive(cashier, false), isTrue);
    expect(store.loginAsStaff(cashier, pin: '2468'), isFalse);
  });

  test('legacy Garson accounts migrate without requiring their old PIN', () {
    final oldHashedRecord = Staff('Eski Garson', 'Garson', pin: '2468').toJson()
      ..remove('pinRequired');
    final hashedWaiter = Staff.fromJson(oldHashedRecord);
    expect(hashedWaiter.pinRequired, isFalse);
    expect(hashedWaiter.verifyPin('2468'), isFalse);

    final plainWaiter = Staff.fromJson({
      'name': 'Eski Garson 2',
      'role': 'Garson',
      'pin': '1234',
    });
    expect(plainWaiter.pinRequired, isFalse);
    expect(plainWaiter.verifyPin('1234'), isFalse);
  });
  testWidgets('PosApp uses Turkish Material localization', (tester) async {
    await tester.pumpWidget(const PosApp());
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.locale, const Locale('tr', 'TR'));
    expect(app.localizationsDelegates, containsAll(GlobalMaterialLocalizations.delegates));
  });

  test('SQLite daily backup is atomically written using the Baku calendar date', () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp('restaurant-pos-backup-atomic-');
    final repository = SqliteStoreRepository(
      databasePath: '${directory.path}/pos.sqlite3',
      backupDirectoryPath: directory.path,
    );
    try {
      await repository.write(jsonEncode({
        'products': [], 'tables': [], 'sales': [], 'staff': [], 'audit': [],
      }));
      final backups = await repository.listBackups();
      final bakuNow = DateTime.now().toUtc().add(const Duration(hours: 4));
      final date = '${bakuNow.year.toString().padLeft(4, '0')}-${bakuNow.month.toString().padLeft(2, '0')}-${bakuNow.day.toString().padLeft(2, '0')}';
      expect(backups.map((backup) => backup.name), contains('restaurant-pos-$date.json'));
      final backupDirectory = Directory('${directory.path}/backups');
      expect(await backupDirectory.list().where((entry) => entry.path.endsWith('.tmp')).length, 0);
    } finally {
      await repository.close();
      await directory.delete(recursive: true);
    }
  });


  test('critical restore preserves advanced records and hashed administrator credential', () async {
    final sourceRepository = MemoryStoreRepository();
    final source = Pos(repository: sourceRepository);
    source.staff.first.setPin('8642');
    final supplier = SupplierRecord(id: 'restore-supplier', name: 'Kurtarma Tedarikçisi');
    expect(source.addSupplier(supplier), isTrue);
    expect(source.recordPurchase(
      supplierId: supplier.id,
      productId: source.products.first.id,
      quantity: 3,
      unitCost: 125,
    ), isTrue);
    expect(source.addCustomer(CustomerRecord(
      id: 'restore-customer', name: 'Kurtarma Müşterisi', phone: '0500000000',
    )), isTrue);
    final reservationTime = azWallTime(azNow()).add(const Duration(days: 3));
    expect(source.addReservation(ReservationRecord(
      id: 'restore-reservation',
      customerName: 'Kurtarma Müşterisi',
      phone: '0500000000',
      dateTime: bakuWallTimeToUtc(reservationTime).toIso8601String(),
      tableId: 7,
      guests: 4,
    )), isTrue);
    expect(source.setProductBarcode(source.products.first, '4891234567890'), isTrue);
    source.save();
    await source.flush();
    final backup = sourceRepository.value!;

    final targetRepository = MemoryStoreRepository();
    final target = Pos(repository: targetRepository);
    await target.load();
    expect(await target.restoreBackup(backup), isTrue);

    expect(target.suppliers.single.id, supplier.id);
    expect(target.purchases.single.total, 375);
    expect(target.customers.single.name, 'Kurtarma Müşterisi');
    expect(target.reservations.single.tableId, 7);
    expect(target.productBarcodes[source.products.first.id], '4891234567890');
    expect(target.staff.single.verifyPin('8642'), isTrue);
    expect(await target.integrityCheck(), isEmpty);
  });
  test('failed persistence rolls in-memory state back and blocks further POS actions', () async {
    final repository = ToggleFailRepository();
    final store = Pos(repository: repository);
    store.save();
    await store.flush();

    final originalStock = store.products.first.stock;
    repository.failWrites = true;

    expect(store.stockChange(store.products.first, 1, note: 'Test düzeltmesi'), isTrue);
    await store.flush();

    expect(store.persistenceFailed, isTrue);
    expect(store.currentUser, isEmpty);
    expect(store.products.first.stock, originalStock);
    expect(store.can('inventory'), isFalse);
    expect(store.stockChange(store.products.first, 1, note: 'İkinci deneme'), isFalse);

    repository.failWrites = false;
    final restored = Pos(repository: repository);
    await restored.load();
    expect(restored.recoveryRequired, isFalse);
    expect(restored.products.first.stock, originalStock);
  });

  test('SQLite preserves refund linkage, stock return and sale ingredient usage across reload', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final directory = await Directory.systemTemp.createTemp('restaurant-pos-refund-v6-');
    final repository = SqliteStoreRepository(
      databasePath: '${directory.path}/pos.sqlite3',
      backupDirectoryPath: directory.path,
    );
    try {
      final store = Pos(repository: repository);
      final product = store.products.first;
      product.stock = 5;
      product.costPrice = 100;
      final ingredient = Ingredient(
        id: 'flour', name: 'Un', unit: 'gram',
        stock: 1000, lowAt: 50, costPerUnit: 1,
      );
      expect(store.addIngredient(ingredient), isTrue);
      expect(store.setRecipe(product, const [RecipeLine(ingredientId: 'flour', quantity: 100)]), isTrue);
      final table = store.tables.first;
      expect(store.add(table, product), isTrue);
      expect(store.sendKitchen(table), isTrue);
      expect(store.openRegister(5000), isTrue);
      expect(store.checkout(table, [PaymentPart('Kart', product.price)]), isTrue);
      final originalIndex = store.sales.length - 1;
      expect(store.sales[originalIndex].ingredientUsage, {'flour': 100});
      expect(store.refundSale(originalIndex, product.price, 'Hatalı ürün', '1234', returnStock: true), isTrue);
      await store.flush();

      final restored = Pos(repository: repository);
      await restored.load();
      expect(restored.recoveryRequired, isFalse);
      expect(restored.sales, hasLength(2));
      expect(restored.sales.first.stockReturned, isTrue);
      expect(restored.sales.first.ingredientUsage, {'flour': 100});
      expect(restored.sales.last.isRefund, isTrue);
      expect(restored.sales.last.refundOfSaleIndex, originalIndex);
      expect(restored.sales.last.reason, 'Hatalı ürün');
      expect(restored.ingredients.single.stock, 1000);
      expect(await restored.integrityCheck(), isEmpty);
    } finally {
      await repository.close();
      await directory.delete(recursive: true);
    }
  });

  test('SQLite preserves ingredient movements and recipe snapshots on open orders', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final directory = await Directory.systemTemp.createTemp('restaurant-pos-ingredient-v7-');
    final repository = SqliteStoreRepository(
      databasePath: '${directory.path}/pos.sqlite3',
      backupDirectoryPath: directory.path,
    );
    try {
      final store = Pos(repository: repository);
      final product = store.products.first;
      product.stock = 5;
      final ingredient = Ingredient(id: 'flour', name: 'Un', unit: 'gram',
        stock: 1000, lowAt: 100, costPerUnit: 2);
      expect(store.addIngredient(ingredient), isTrue);
      expect(store.setRecipe(product, const [RecipeLine(ingredientId: 'flour', quantity: 100)]), isTrue);
      final table = store.tables.first;
      expect(store.add(table, product), isTrue);
      expect(store.setRecipe(product, const [RecipeLine(ingredientId: 'flour', quantity: 200)]), isTrue);
      await store.flush();

      final restored = Pos(repository: repository);
      await restored.load();
      expect(restored.tables.first.items.single.ingredientUsage, {'flour': 100});
      expect(restored.reservedIngredientStock('flour'), 100);
      expect(restored.ingredientMovements, hasLength(1));

      final restoredTable = restored.tables.first;
      expect(restored.sendKitchen(restoredTable), isTrue);
      expect(restored.openRegister(1000), isTrue);
      expect(restored.checkout(restoredTable,
        [PaymentPart('Kart', product.price)]), isTrue);
      await restored.flush();

      final finalState = Pos(repository: repository);
      await finalState.load();
      expect(finalState.ingredients.single.stock, 900);
      expect(finalState.ingredientMovements, hasLength(2));
      expect(finalState.ingredientMovements.last.type, 'Satış');
      expect(finalState.sales.single.ingredientUsage, {'flour': 100});
      expect(await finalState.integrityCheck(), isEmpty);
    } finally {
      await repository.close();
      await directory.delete(recursive: true);
    }
  });

}
