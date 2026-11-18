import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/main.dart';

void main() {
  testWidgets('POS home screen renders', (tester) async {
    await tester.pumpWidget(const PosApp());
    await tester.pump();
    expect(find.text('Restaurant POS'), findsOneWidget);
    expect(find.text('Masalar'), findsOneWidget);
  });
}
