import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/main.dart';

void main() {
  testWidgets('POS requires admin PIN setup before opening the app', (tester) async {
    await tester.pumpWidget(const PosApp());
    await tester.pumpAndSettle();

    expect(find.text('Yönetici PIN kodunu oluştur'), findsOneWidget);
    expect(find.text('Yeni 4 haneli PIN'), findsOneWidget);

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '2468');
    await tester.enterText(fields.at(1), '2468');
    await tester.tap(find.text('PIN oluştur ve devam et'));
    await tester.pumpAndSettle();

    expect(find.text('Restaurant POS'), findsOneWidget);
    expect(find.text('Masalar'), findsOneWidget);
  });
}
