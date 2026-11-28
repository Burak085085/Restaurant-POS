// Runtime user-interface translation.
//
// The UI is written in Turkish. The `Text` widget below shadows the Material
// `Text` inside main.dart and translates its string at build time using the
// active locale, so existing (also `const`) widgets keep working unchanged.
// Stored data (product names, payment method codes, audit rows) is never
// translated or modified; only what is displayed changes.
import 'package:material_ui/material_ui.dart' as m;
import 'package:shared_preferences/shared_preferences.dart';

import 'i18n_strings.dart';

/// Supported languages: code → native name. Turkish is the source language.
const Map<String, String> kAppLanguages = {
  'tr': 'Türkçe',
  'az': 'Azərbaycan dili',
  'en': 'English',
  'ru': 'Русский',
  'pl': 'Polski',
  'zh': '中文',
  'ar': 'العربية',
  'es': 'Español',
};
const String kLanguagePreferenceKey = 'app_language';

/// Currently selected language code. Listened to by the app root.
final m.ValueNotifier<String> appLanguage = m.ValueNotifier<String>('tr');

Future<void> loadAppLanguage() async {
  try {
    final preferences = await SharedPreferences.getInstance();
    final code = preferences.getString(kLanguagePreferenceKey);
    if (code != null && kAppLanguages.containsKey(code)) appLanguage.value = code;
  } catch (_) {
    // Preference storage unavailable: keep Turkish.
  }
}

Future<void> setAppLanguage(String code) async {
  if (!kAppLanguages.containsKey(code)) return;
  appLanguage.value = code;
  try {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(kLanguagePreferenceKey, code);
  } catch (_) {
    // The choice still applies for this session.
  }
}

class _Template {
  _Template(this.key, this.pattern);
  final String key;
  final RegExp pattern;
}

List<_Template>? _templates;
final Map<String, Map<String, String>> _cache = {};

List<_Template> _compiledTemplates() => _templates ??= [
  for (final key in kTranslations.keys)
    if (key.contains('{0}'))
      _Template(key, RegExp('^${key.split(RegExp(r'\{\d\}')).map(RegExp.escape).join('(.+?)')}\$', dotAll: true)),
]..sort((a, b) => b.key.length.compareTo(a.key.length));

String? _exact(String text, int index) {
  final values = kTranslations[text];
  return values == null ? null : values[index];
}

String? _fromTemplate(String text, int index) {
  for (final template in _compiledTemplates()) {
    final match = template.pattern.firstMatch(text);
    if (match == null) continue;
    var result = kTranslations[template.key]![index];
    for (var group = 1; group <= match.groupCount; group++) {
      final value = match.group(group) ?? '';
      result = result.replaceAll('{${group - 1}}', _exact(value, index) ?? value);
    }
    return result;
  }
  return null;
}

/// Translates a Turkish UI text into [languageCode]. Unknown texts (product
/// names, numbers, user input) are returned unchanged.
String translateUi(String text, [String? languageCode]) {
  final code = languageCode ?? appLanguage.value;
  final index = kLanguageOrder.indexOf(code);
  if (index < 0 || text.isEmpty) return text;
  final cache = _cache.putIfAbsent(code, () => {});
  final cached = cache[text];
  if (cached != null) return cached;
  var result = _exact(text, index) ?? _fromTemplate(text, index);
  if (result == null && text.contains(' · ')) {
    result = text.split(' · ').map((part) => _exact(part, index) ?? _fromTemplate(part, index) ?? part).join(' · ');
  }
  result ??= text;
  if (cache.length > 4000) cache.clear();
  cache[text] = result;
  return result;
}

/// Shorthand for non-widget strings (tooltips, labels, titles).
String tr(String text) => translateUi(text);

/// Drop-in replacement for Material `Text` that translates its content.
class Text extends m.StatelessWidget {
  const Text(this.data, {super.key, this.style, this.textAlign, this.maxLines,
      this.softWrap, this.overflow});
  final String data;
  final m.TextStyle? style;
  final m.TextAlign? textAlign;
  final int? maxLines;
  final bool? softWrap;
  final m.TextOverflow? overflow;

  @override
  m.Widget build(m.BuildContext context) {
    final code = m.Localizations.maybeLocaleOf(context)?.languageCode ?? appLanguage.value;
    return m.Text(translateUi(data, code), style: style, textAlign: textAlign,
        maxLines: maxLines, softWrap: softWrap, overflow: overflow);
  }
}
