import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/storage.dart';
import 'package:restaurant_pos/main.dart';

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
    expect(store.qty(table, 0, -1), isFalse);
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

}
