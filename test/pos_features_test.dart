import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/main.dart';

void main() {
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
      expect(pos.checkout(table, [PaymentPart('Nakit', product.price)]), isTrue);
      expect(ingredient.stock, 900);
      expect(pos.sales.single.items.single.unitCost, 250);
      await pos.flush();
    });

    test('integrity check reports a clean new store', () async {
      final pos = Pos(repository: MemoryStoreRepository());
      expect(await pos.integrityCheck(), isEmpty);
    });
  });
}
