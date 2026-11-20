import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/storage.dart';
import 'package:restaurant_pos/main.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('Azerbaijani manat formatting uses qəpik precision', () {
    expect(money(0), '0,00 ₼');
    expect(money(5), '0,05 ₼');
    expect(money(1250), '12,50 ₼');
  });

  test('money parser converts comma decimals to qəpik', () {
    expect(parseMoney('12,50'), 1250);
    expect(parseMoney('3.25'), 325);
    expect(parseMoney('invalid'), 0);
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
    expect(store.qty(table, 0, -1), isTrue);
    expect(table.items, hasLength(1));
    expect(table.items.single.sent, isTrue);
    expect(store.reservedStock(product.id), 1);
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
    final restored = Staff.fromJson(staff.toJson());
    expect(restored.verifyPin('5831'), isTrue);
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
    final repository = MemoryStoreRepository(value: '{"products":[{"id":"old","category":"Test","name":"Old","price":100,"stock":5,"lowAt":1,"active":true}],"tables":[],"sales":[],"staff":[],"audit":[]}');
    final store = Pos(repository: repository);
    await store.load();
    const backup = '{"products":[{"id":"new","category":"Test","name":"Restored","price":250,"stock":8,"lowAt":2,"active":true}],"tables":[],"sales":[],"staff":[],"audit":[]}';

    expect(await store.restoreBackup(backup), isTrue);
    expect(store.products.single.name, 'Restored');
    expect(repository.backupFiles, hasLength(1));
    expect(repository.backupFiles.values.single, contains('"Old"'));
  });

  test('invalid backup cannot replace current data', () async {
    final repository = MemoryStoreRepository(value: '{"products":[{"id":"old","category":"Test","name":"Old","price":100,"stock":5,"lowAt":1,"active":true}],"tables":[],"sales":[],"staff":[],"audit":[]}');
    final store = Pos(repository: repository);
    await store.load();

    expect(await store.restoreBackup('{broken-json'), isFalse);
    expect(store.products.single.name, 'Old');
    expect(repository.backupFiles, isEmpty);
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

  test('corrupt local data is backed up before defaults are restored', () async {
    final repository = MemoryStoreRepository(value: '{broken-json');
    final store = Pos(repository: repository);
    await store.load();
    expect(repository.corruptBackup, '{broken-json');
    expect(repository.value, isNull);
    expect(store.tables, hasLength(kTableCount));
    expect(store.staff.single.name, 'Admin');
  });


  test('money parser rejects non-finite values', () {
    expect(parseMoney('NaN'), 0);
    expect(parseMoney('Infinity'), 0);
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
          'table': 1, 'total': 650, 'discount': 50, 'registerSessionId': 123,
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
}
