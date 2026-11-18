import 'package:flutter_test/flutter_test.dart';
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
}