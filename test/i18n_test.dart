import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' hide Text;
import 'package:material_ui/material_ui.dart' as m show Text;
import 'package:restaurant_pos/i18n.dart';
import 'package:restaurant_pos/i18n_strings.dart';
import 'package:restaurant_pos/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every translation has all languages and matching placeholders', () {
    final placeholder = RegExp(r'\{\d\}');
    for (final entry in kTranslations.entries) {
      expect(entry.value, hasLength(kLanguageOrder.length), reason: entry.key);
      final expected = placeholder.allMatches(entry.key).map((m) => m.group(0)).toSet();
      for (final value in entry.value) {
        expect(value.trim(), isNotEmpty, reason: entry.key);
        expect(placeholder.allMatches(value).map((m) => m.group(0)).toSet(), expected, reason: '${entry.key} → $value');
      }
    }
    expect(kAppLanguages.keys.toSet(), {'tr', ...kLanguageOrder});
  });

  test('exact, template, nested and segmented texts are translated', () {
    expect(translateUi('Masalar', 'en'), 'Tables');
    expect(translateUi('Masalar', 'tr'), 'Masalar');
    expect(translateUi('Masa 7', 'ru'), 'Стол 7');
    expect(translateUi('Masa 7', 'zh'), '7号桌');
    expect(translateUi('Nakit ekle', 'es'), 'Añadir Efectivo');
    expect(translateUi('Kalan: 12,50 ₼', 'pl'), 'Pozostało: 12,50 ₼');
    expect(translateUi('Ali · Kasiyer', 'az'), 'Ali · Kassir');
    expect(translateUi('Tavuk döner', 'en'), 'Tavuk döner');
    expect(translateUi('Bilinmeyen metin', 'ar'), 'Bilinmeyen metin');
  });

  test('language choice is persisted', () async {
    SharedPreferences.setMockInitialValues({});
    await setAppLanguage('ar');
    appLanguage.value = 'tr';
    await loadAppLanguage();
    expect(appLanguage.value, 'ar');
    await setAppLanguage('xx');
    expect(appLanguage.value, 'ar');
    await setAppLanguage('tr');
  });

  testWidgets('switching language translates the sign-in screen and uses RTL for Arabic', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const PosApp(showSplash: false));
    await tester.pumpAndSettle();
    expect(find.text('Yönetici PIN kodunu oluştur'), findsOneWidget);

    await setAppLanguage('en');
    await tester.pumpAndSettle();
    expect(find.text('Create manager PIN'), findsOneWidget);

    await setAppLanguage('ar');
    await tester.pumpAndSettle();
    expect(find.text('إنشاء PIN المدير'), findsOneWidget);
    final direction = Directionality.of(tester.element(find.byType(m.Text).first));
    expect(direction, TextDirection.rtl);

    await setAppLanguage('tr');
    await tester.pumpAndSettle();
  });

  testWidgets('opening animation completes and reveals the app', (tester) async {
    await tester.pumpWidget(const PosApp());
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SplashGate), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('Yönetici PIN kodunu oluştur'), findsOneWidget);
  });
}
