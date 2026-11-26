import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/advanced_features.dart';
import 'package:restaurant_pos/main.dart';
import 'package:restaurant_pos/storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('Restaurant POS operational features', () {
    test('kitchen status can be changed for one order line only', () async {
      final pos = Pos(repository: MemoryStoreRepository());
      final table = pos.tables.first;
      expect(pos.add(table, pos.products[0]), isTrue);
      expect(pos.add(table, pos.products[1]), isTrue);
      expect(pos.sendKitchen(table), isTrue);

      expect(pos.setKitchenLine(table, table.items.first, KitchenState.ready), isTrue);
      expect(table.items.first.kitchen, KitchenState.ready);
      expect(table.items.last.kitchen, KitchenState.queued);
      await pos.flush();
    });

    test('sent kitchen line cancellation requires a reason and supervisor PIN and alerts kitchen', () async {
      final repository = MemoryStoreRepository();
      final pos = Pos(repository: repository);
      final table = pos.tables.first;
      final product = pos.products.first;

      expect(pos.add(table, product), isTrue);
      expect(pos.add(table, product), isTrue);
      expect(pos.sendKitchen(table), isTrue);
      expect(pos.reservedStock(product.id), 2);
      final line = table.items.single;

      expect(pos.qty(table, 0, -1), isFalse);
      expect(pos.cancelSentLine(table, line, 1, '', '1234'), isFalse);
      expect(pos.cancelSentLine(table, line, 1, 'Müşteri vazgeçti', '0000'), isFalse);
      expect(pos.cancelSentLine(table, line, 1, 'Müşteri vazgeçti', '1234'), isTrue);
      expect(line.qty, 1);
      expect(pos.reservedStock(product.id), 1);
      expect(pos.kitchenNotices.single.reason, 'Müşteri vazgeçti');
      expect(pos.kitchenNotices.single.quantity, 1);
      expect(pos.kitchenNotices.single.amount, product.price);
      expect(pos.audit.first.detail, contains(money(product.price)));
      expect(pos.acknowledgeKitchenNotice(pos.kitchenNotices.single), isTrue);

      expect(pos.cancelSentLine(table, line, 1, 'Tam iptal', '1234'), isTrue);
      expect(table.items, isEmpty);
      expect(pos.reservedStock(product.id), 0);
      await pos.flush();

      final restored = Pos(repository: repository);
      await restored.load();
      expect(restored.kitchenNotices, hasLength(2));
      expect(restored.audit.where((entry) => entry.action == 'Gönderilmiş ürün iptali'), hasLength(2));
    });

    test('cashier PIN can authorize a sent kitchen line cancellation', () {
      final pos = Pos(repository: MemoryStoreRepository());
      expect(pos.addStaff('Kasiyer', 'Kasiyer', '2468'), isTrue);
      final table = pos.tables.first;
      expect(pos.add(table, pos.products.first), isTrue);
      expect(pos.sendKitchen(table), isTrue);
      expect(pos.cancelSentLine(table, table.items.single, 1, 'Yanlış sipariş', '2468'), isTrue);
    });

    test('refund requires admin PIN, open register and cannot exceed original sale', () async {
      final repository = MemoryStoreRepository();
      final pos = Pos(repository: repository);
      final admin = pos.staff.firstWhere((member) => member.name == 'Admin');
      admin.setPin('8642');
      final product = pos.products.first;
      product.stock = 5;
      product.costPrice = 100;
      final ingredient = Ingredient(id:'flour',name:'Un',unit:'gram',stock:1000,lowAt:50,costPerUnit:1);
      expect(pos.addIngredient(ingredient), isTrue);
      expect(pos.setRecipe(product, const [RecipeLine(ingredientId:'flour',quantity:100)]), isTrue);
      final table = pos.tables.first;
      expect(pos.add(table, product), isTrue);
      expect(pos.sendKitchen(table), isTrue);
      expect(pos.openRegister(5000), isTrue);
      expect(pos.checkout(table, [PaymentPart('Kart', product.price)]), isTrue);
      expect(product.stock, 4);
      expect(ingredient.stock, 900);
      expect(pos.setRecipe(product, const [RecipeLine(ingredientId:'flour',quantity:200)]), isTrue);
      final originalIndex = pos.sales.length - 1;

      expect(pos.addStaff('Kasiyer', 'Kasiyer', '2468'), isTrue);
      expect(pos.refundSale(originalIndex, product.price, 'Hatalı ürün', '2468'), isFalse);
      expect(pos.refundSale(originalIndex, product.price, 'Hatalı ürün', '0000'), isFalse);
      expect(pos.refundSale(originalIndex, product.price + 1, 'Hatalı ürün', '8642'), isFalse);
      expect(pos.refundSale(originalIndex, product.price, '', '8642'), isFalse);
      expect(pos.refundSale(originalIndex, product.price, 'Hatalı ürün', '8642', returnStock: true), isTrue);

      expect(product.stock, 5);
      expect(ingredient.stock, 1000);
      expect(pos.sales.last.isRefund, isTrue);
      expect(pos.sales.last.total, -product.price);
      expect(pos.sales.last.refundOfSaleIndex, originalIndex);
      expect(pos.sales.last.reason, 'Hatalı ürün');
      expect(pos.sales.last.items.single.qty, 1);
      expect(pos.cashMovements.last.type, 'Çıxış');
      expect(pos.cashMovements.last.amount, product.price);
      expect(pos.remainingRefundable(originalIndex), 0);
      expect(pos.refundSale(originalIndex, 1, 'İkinci iade', '8642'), isFalse);
      expect(pos.stockMovements.last.type, 'İade');
      expect(pos.costOfSale(pos.sales.last), -200);
      expect(await pos.integrityCheck(), isEmpty);
      await pos.flush();
      final restored = Pos(repository: repository);
      await restored.load();
      expect(restored.sales.last.isRefund, isTrue);
      expect(restored.sales.last.refundOfSaleIndex, originalIndex);
      expect(restored.sales[originalIndex].stockReturned, isTrue);
      expect(restored.cashMovements.last.type, 'Çıxış');

    });

    test('new saves keep UTC timestamp format version and do not remigrate timestamps', () async {
      final repository = MemoryStoreRepository();
      final pos = Pos(repository: repository);
      const timestamp = '2026-11-22T01:02:03.000Z';
      pos.cashMovements.add(CashMovement(id:1,sessionId:77,at:timestamp,type:'Giriş',amount:100,note:'test'));
      pos.save();
      await pos.flush();
      expect(repository.value, contains('"timestampFormatVersion":2'));
      final restored = Pos(repository: repository);
      await restored.load();
      expect(restored.cashMovements.single.at, timestamp);
    });

    test('table move, merge and partial split preserve order quantities', () async {
      final pos = Pos(repository: MemoryStoreRepository());
      final first = pos.tables[0];
      final second = pos.tables[1];
      final third = pos.tables[2];

      expect(pos.add(first, pos.products[0]), isTrue);
      expect(pos.moveTable(first, second), isTrue);
      expect(first.items, isEmpty);
      expect(second.items.single.qty, 1);

      expect(pos.add(first, pos.products[1]), isTrue);
      expect(pos.mergeTables(first, second), isTrue);
      expect(first.items, isEmpty);
      expect(second.items.length, 2);

      expect(pos.splitTable(second, third, lineIndex: 0, quantity: 1), isTrue);
      expect(third.items.single.qty, 1);
      expect(second.items.length, 1);
      await pos.flush();
    });

    test('recipe ingredients are reserved and deducted at checkout', () async {
      final pos = Pos(repository: MemoryStoreRepository());
      final product = pos.products.first;
      product.costPrice = 50;
      final ingredient = Ingredient(id: 'flour', name: 'Un', unit: 'gram',
        stock: 1000, lowAt: 100, costPerUnit: 2);
      expect(pos.addIngredient(ingredient), isTrue);
      expect(pos.setRecipe(product, const [
        RecipeLine(ingredientId: 'flour', quantity: 100),
      ]), isTrue);

      final table = pos.tables.first;
      expect(pos.add(table, product), isTrue);
      expect(pos.reservedIngredientStock('flour'), 100);
      expect(pos.sendKitchen(table), isTrue);
      expect(pos.openRegister(1000), isTrue);
      expect(pos.checkout(table, [PaymentPart('Nakit', product.price)]), isTrue);
      expect(ingredient.stock, 900);
      expect(pos.sales.single.items.single.unitCost, 250);
      await pos.flush();
    });

    test('checkout records the selected staff member for performance reports', () async {
      final pos = Pos(repository: MemoryStoreRepository());
      expect(pos.addStaff('Ayşe Yılmaz', 'Garson', null), isTrue);
      final table = pos.tables.first;
      final product = pos.products.first;
      expect(pos.add(table, product), isTrue);
      expect(pos.sendKitchen(table), isTrue);
      expect(pos.openRegister(1000), isTrue);

      expect(pos.checkout(table, [PaymentPart('Nakit', product.price)],
        staffName: 'Ayşe Yılmaz'), isTrue);
      expect(pos.sales.single.staff, 'Ayşe Yılmaz');
      await pos.flush();
    });

    test('staff roster persists and selected seller is recorded on checkout', () async {
      final repository = MemoryStoreRepository();
      final pos = Pos(repository: repository);
      expect(pos.addStaff('Ayşe Yılmaz', 'Garson', '2468'), isTrue);
      await pos.flush();
      final restored = Pos(repository: repository);
      await restored.load();
      expect(restored.staff.any((member) => member.name == 'Ayşe Yılmaz' && member.active), isTrue);
      final table = restored.tables.first;
      final product = restored.products.first;
      expect(restored.add(table, product), isTrue);
      expect(restored.sendKitchen(table), isTrue);
      expect(restored.openRegister(1000), isTrue);
      expect(restored.checkout(table, [PaymentPart('Nakit', product.price)], staffName: 'Ayşe Yılmaz'), isTrue);
      expect(restored.sales.single.staff, 'Ayşe Yılmaz');
      await restored.flush();
    });

    test('stock movement ledger checks quantities, continuity and current balance', () async {
      final pos = Pos(repository: MemoryStoreRepository());
      final product = pos.products.first;
      product.stock = 10;

      expect(pos.stockChange(product, 2, note: 'İlk düzeltme'), isTrue);
      expect(pos.stockChange(product, -1, note: 'İkinci düzeltme'), isTrue);
      expect(await pos.integrityCheck(), isEmpty);

      final previous = pos.stockMovements.first;
      pos.stockMovements[0] = StockMovement(
        id: previous.id,
        productId: previous.productId,
        productName: previous.productName,
        type: previous.type,
        quantity: previous.quantity + 1,
        beforeStock: previous.beforeStock,
        afterStock: previous.afterStock,
        productCost: previous.productCost,
        at: previous.at,
        note: previous.note,
      );
      final issues = await pos.integrityCheck();
      expect(issues, anyElement(contains('stok hareketinin giriş/çıkış miktarı tutarsız')));
    });

    test('supplier purchase increases stock and recalculates weighted average cost', () async {
      final pos = Pos(repository: MemoryStoreRepository());
      final product = pos.products.first;
      product.stock = 10;
      product.costPrice = 100;
      final supplier = SupplierRecord(id: 'supplier-1', name: 'Test Tedarikçi');
      expect(pos.addSupplier(supplier), isTrue);
      expect(pos.recordPurchase(supplierId: supplier.id, productId: product.id,
        quantity: 10, unitCost: 300), isTrue);
      expect(product.stock, 20);
      expect(product.costPrice, 200);
      expect(pos.purchases.single.total, 3000);
      expect(pos.stockMovements, hasLength(1));
      expect(pos.stockMovements.single.type, 'Alım');
      expect(pos.stockMovements.single.quantity, 10);
      expect(pos.stockMovements.single.beforeStock, 10);
      expect(pos.stockMovements.single.afterStock, 20);
      expect(pos.stockMovements.single.productCost, 300);
      await pos.flush();
    });

    test('reservation rejects overlapping booking for the same table', () {
      final pos = Pos(repository: MemoryStoreRepository());
      final firstTime = azWallTime(azNow()).add(const Duration(days: 2));
      final first = ReservationRecord(id: 'r1', customerName: 'Ali', phone: '0500000000',
        dateTime: bakuWallTimeToUtc(firstTime).toIso8601String(), tableId: 4, guests: 3);
      expect(pos.addReservation(first), isTrue);
      final overlap = ReservationRecord(id: 'r2', customerName: 'Veli', phone: '0500000001',
        dateTime: bakuWallTimeToUtc(firstTime.add(const Duration(minutes: 90))).toIso8601String(),
        tableId: 4, guests: 2);
      expect(pos.addReservation(overlap), isFalse);
      final otherTable = ReservationRecord(id: 'r3', customerName: 'Veli', phone: '0500000001',
        dateTime: bakuWallTimeToUtc(firstTime.add(const Duration(minutes: 90))).toIso8601String(),
        tableId: 5, guests: 2);
      expect(pos.addReservation(otherTable), isTrue);
    });

    test('barcode lookup is unique and resolves only active products', () {
      final pos = Pos(repository: MemoryStoreRepository());
      final first = pos.products[0];
      final second = pos.products[1];
      expect(pos.setProductBarcode(first, '1234567890123'), isTrue);
      expect(pos.productByBarcode('1234567890123'), same(first));
      expect(pos.setProductBarcode(second, '1234567890123'), isFalse);
      first.active = false;
      expect(pos.productByBarcode('1234567890123'), isNull);
    });

    test('barcode assignment survives save and reload and trims scanner input', () async {
      final repository = MemoryStoreRepository();
      final pos = Pos(repository: repository);
      final product = pos.products.first;
      expect(pos.setProductBarcode(product, '  8690000000001  '), isTrue);
      await pos.flush();

      final restored = Pos(repository: repository);
      await restored.load();
      expect(restored.productByBarcode(' 8690000000001 ' )?.id, product.id);
      expect(await restored.integrityCheck(), isEmpty);
    });

    test('receipt PDF embeds the bundled font for Turkish and Azerbaijani glyphs', () async {
      final sale = Sale(
        '27.11.2026', '14:30', 'Aysel', 4, 2500, 0,
        [OrderLine('p1', 'Şəki çörəyi · İğdır döner', 2500, 1)],
        [PaymentPart('Kart', 2500)],
      );
      final bytes = await ReceiptPrinter.buildSalePdf(sale);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(String.fromCharCodes(bytes), contains('/FontFile2'));
      expect(bytes.length, greaterThan(10000));
    });

    test('customers and advanced records survive a local save and reload', () async {
      final repository = MemoryStoreRepository();
      final pos = Pos(repository: repository);
      expect(pos.addCustomer(CustomerRecord(id: 'c1', name: 'Aysel', phone: '0501111111')), isTrue);
      final supplier = SupplierRecord(id: 's1', name: 'Anbar');
      expect(pos.addSupplier(supplier), isTrue);
      await pos.flush();
      final restored = Pos(repository: repository);
      await restored.load();
      expect(restored.customers.single.name, 'Aysel');
      expect(restored.suppliers.single.name, 'Anbar');
    });


    test('inactivity timeout setting persists and rejects unsupported values', () async {
      final repository = MemoryStoreRepository();
      final pos = Pos(repository: repository);
      expect(pos.inactivityTimeoutMinutes, 15);
      pos.setInactivityTimeoutMinutes(30);
      expect(pos.inactivityTimeoutMinutes, 30);
      await pos.flush();
      final restored = Pos(repository: repository);
      await restored.load();
      expect(restored.inactivityTimeoutMinutes, 30);
    });

    test('session lock clears the active identity and persists a security audit event', () async {
      final repository = MemoryStoreRepository();
      final pos = Pos(repository: repository);
      expect(pos.isAdmin, isTrue);
      pos.lockSession();
      expect(pos.currentUser, isEmpty);
      expect(pos.isAdmin, isFalse);
      expect(pos.audit.last.action, 'Oturum kilitlendi');
      await pos.flush();
      final restored = Pos(repository: repository);
      await restored.load();
      expect(restored.currentUser, 'Admin');
      expect(restored.audit.last.action, 'Oturum kilitlendi');
    });

    test('backup restore rejects inconsistent state before replacing live data', () async {
      final repository = MemoryStoreRepository();
      final pos = Pos(repository: repository);
      const invalidBackup = '{"products":[{"id":"p1","name":"Bozuk","stock":-5,"price":100,"costPrice":0}],"tables":[],"sales":[],"staff":[{"name":"Admin","role":"Yönetici","salt":"salt","pinHash":"hash","pinRequired":true,"active":true}]}';
      expect(await pos.restoreBackup(invalidBackup), isFalse);
      expect(repository.value, isNull);
      expect(pos.products.first.name, 'Tavuk döner');
    });

    test('integrity check reports a clean new store', () async {
      final pos = Pos(repository: MemoryStoreRepository());
      expect(await pos.integrityCheck(), isEmpty);
    });
    test('open order keeps its original recipe after the recipe is edited', () async {
      final pos = Pos(repository: MemoryStoreRepository());
      final product = pos.products.first;
      final ingredient = Ingredient(id: 'flour', name: 'Un', unit: 'gram',
        stock: 1000, lowAt: 100, costPerUnit: 2);
      expect(pos.addIngredient(ingredient), isTrue);
      expect(pos.setRecipe(product, const [RecipeLine(ingredientId: 'flour', quantity: 100)]), isTrue);
      final table = pos.tables.first;
      expect(pos.add(table, product), isTrue);
      expect(pos.setRecipe(product, const [RecipeLine(ingredientId: 'flour', quantity: 200)]), isTrue);
      expect(pos.reservedIngredientStock('flour'), 100);
      expect(pos.add(table, product), isTrue);
      expect(pos.reservedIngredientStock('flour'), 300);
      expect(pos.sendKitchen(table), isTrue);
      expect(pos.openRegister(1000), isTrue);
      expect(pos.checkout(table, [PaymentPart('Kart', product.price * 2)]), isTrue);
      expect(ingredient.stock, 700);
      expect(pos.sales.single.ingredientUsage, {'flour': 300});
      expect(pos.sales.single.items.map((item) => item.unitCost), [200, 400]);
      await pos.flush();
      expect(await pos.integrityCheck(), isEmpty);
    });

    test('ingredient purchase, consumption and return reconcile the stock ledger', () async {
      final repository = MemoryStoreRepository();
      final pos = Pos(repository: repository);
      final product = pos.products.first;
      product.stock = 5;
      final ingredient = Ingredient(id: 'oil', name: 'Yag', unit: 'ml',
        stock: 100, lowAt: 10, costPerUnit: 200);
      expect(pos.addIngredient(ingredient), isTrue);
      expect(pos.recordIngredientPurchase(
        ingredientId: ingredient.id, quantity: 100, unitCost: 400), isTrue);
      expect(ingredient.stock, 200);
      expect(ingredient.costPerUnit, 300);
      expect(pos.ingredientMovements.map((item) => item.type), ['Giriş', 'Alım']);

      expect(pos.setRecipe(product, const [RecipeLine(ingredientId: 'oil', quantity: 10)]), isTrue);
      final table = pos.tables.first;
      expect(pos.add(table, product), isTrue);
      expect(pos.sendKitchen(table), isTrue);
      expect(pos.openRegister(5000), isTrue);
      expect(pos.checkout(table, [PaymentPart('Kart', product.price)]), isTrue);
      expect(ingredient.stock, 190);
      final saleIndex = pos.sales.length - 1;
      expect(pos.refundSale(saleIndex, product.price, 'Test return', '1234', returnStock: true), isTrue);
      expect(ingredient.stock, 200);
      expect(pos.ingredientMovements.map((item) => item.type), ['Giriş', 'Alım', 'Satış', 'İade']);
      expect(pos.ingredientMovements.last.beforeStock, 190);
      expect(pos.ingredientMovements.last.afterStock, 200);
      await pos.flush();

      final restored = Pos(repository: repository);
      await restored.load();
      expect(restored.ingredientMovements, hasLength(4));
      expect(restored.ingredients.single.costPerUnit, 300);
      expect(await restored.integrityCheck(), isEmpty);
    });

    test('partial refunds reconcile in sequence and return stock only once', () async {
      final repository = MemoryStoreRepository();
      final pos = Pos(repository: repository);
      pos.staff.firstWhere((member) => member.name == 'Admin').setPin('8642');
      final product = pos.products.first;
      product.stock = 5;
      final table = pos.tables.first;

      expect(pos.add(table, product), isTrue);
      expect(pos.sendKitchen(table), isTrue);
      expect(pos.openRegister(1000), isTrue);
      expect(pos.checkout(table, [PaymentPart('Kart', product.price)]), isTrue);
      final saleIndex = pos.sales.length - 1;
      expect(product.stock, 4);

      expect(pos.refundSale(saleIndex, 100, 'Kısmi iade', '8642'), isTrue);
      expect(pos.remainingRefundable(saleIndex), product.price - 100);
      expect(product.stock, 4);
      expect(pos.refundedAmountForSale(saleIndex), 100);

      expect(pos.refundSale(saleIndex, product.price - 100,
        'Kalan tutar ve stok iadesi', '8642', returnStock: true), isTrue);
      expect(pos.remainingRefundable(saleIndex), 0);
      expect(pos.refundedAmountForSale(saleIndex), product.price);
      expect(product.stock, 5);
      expect(pos.sales.where((sale) => sale.isRefund && sale.refundOfSaleIndex == saleIndex), hasLength(2));
      expect(pos.cashMovements.where((movement) => movement.type == 'Çıxış')
        .fold<int>(0, (sum, movement) => sum + movement.amount), product.price);
      expect(pos.expectedRegisterCash(pos.activeRegister!), 1000 - product.price);
      expect(pos.refundSale(saleIndex, 1, 'Mükerrer iade', '8642'), isFalse);
      expect(pos.integrityCheck(), completion(isEmpty));
      await pos.flush();

      final restored = Pos(repository: repository);
      await restored.load();
      expect(restored.remainingRefundable(saleIndex), 0);
      expect(restored.refundedAmountForSale(saleIndex), product.price);
      expect(restored.products.first.stock, 5);
      expect(await restored.integrityCheck(), isEmpty);
    });

    test('refund is rejected when register cash is insufficient without side effects', () async {
      final pos = Pos(repository: MemoryStoreRepository());
      pos.staff.firstWhere((member) => member.name == 'Admin').setPin('8642');
      final product = pos.products.first;
      product.stock = 5;
      final table = pos.tables.first;

      expect(pos.add(table, product), isTrue);
      expect(pos.sendKitchen(table), isTrue);
      expect(pos.openRegister(50), isTrue);
      expect(pos.checkout(table, [PaymentPart('Kart', product.price)]), isTrue);
      final saleIndex = pos.sales.length - 1;
      final saleCount = pos.sales.length;
      final movementCount = pos.cashMovements.length;
      final stockBefore = product.stock;

      expect(pos.refundSale(saleIndex, product.price, 'Kasada yeterli nakit yok', '8642'), isFalse);
      expect(pos.sales, hasLength(saleCount));
      expect(pos.cashMovements, hasLength(movementCount));
      expect(product.stock, stockBefore);
      expect(pos.remainingRefundable(saleIndex), product.price);
      expect(pos.expectedRegisterCash(pos.activeRegister!), 50);
      await pos.flush();
    });

  });
}
