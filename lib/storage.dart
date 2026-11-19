import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String legacyStoreKey = 'restaurant_pos_v2';
const int storeDatabaseVersion = 3;

bool isDailyBackupFileName(String name) {
  final match = RegExp(r'^restaurant-pos-[0-9]{4}-[0-9]{2}-[0-9]{2}[.]json').firstMatch(name);
  return match != null && match.end == name.length;
}

bool isRestorableBackupFileName(String name) =>
    isDailyBackupFileName(name) ||
    (name.startsWith('restaurant-pos-pre-restore-') && name.endsWith('.json'));

class BackupFile {
  final String name;
  final DateTime modifiedAt;
  final int sizeBytes;
  const BackupFile(this.name, this.modifiedAt, this.sizeBytes);
}

abstract class StoreRepository {
  Future<String?> read();
  Future<void> write(String payload);
  Future<void> backupCorrupt(String payload);
  Future<void> backupBeforeRestore(String payload);
  Future<List<BackupFile>> listBackups();
  Future<String?> readBackup(String name);
}

class SqliteStoreRepository implements StoreRepository {
  SqliteStoreRepository({String? databasePath, String? backupDirectoryPath})
      : _databasePath = databasePath,
        _backupDirectoryPath = backupDirectoryPath;

  final String? _databasePath;
  final String? _backupDirectoryPath;
  Database? _database;

  Future<Database> _open() async {
    if (_database != null) return _database!;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final resolvedPath = _databasePath ??
        path.join((await getApplicationDocumentsDirectory()).path, 'restaurant_pos.sqlite3');
    _database = await openDatabase(
      resolvedPath,
      version: storeDatabaseVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA journal_mode = WAL');
        await db.execute('PRAGMA synchronous = FULL');
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await db.execute('CREATE TABLE app_state (id INTEGER PRIMARY KEY CHECK (id = 1), payload TEXT NOT NULL, updated_at TEXT NOT NULL)');
        await _createNormalizedSchema(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) await _createNormalizedSchema(db);
        if (oldVersion < 3) {
          final columns = await db.rawQuery('PRAGMA table_info(sales)');
          if (!columns.any((column) => column['name'] == 'register_session_id')) {
            await db.execute('ALTER TABLE sales ADD COLUMN register_session_id INTEGER REFERENCES register_sessions(id)');
          }
        }
      },
    );
    return _database!;
  }

  Future<void> _createNormalizedSchema(DatabaseExecutor db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS app_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
    await db.execute('CREATE TABLE IF NOT EXISTS products (id TEXT PRIMARY KEY, category TEXT NOT NULL, name TEXT NOT NULL, price INTEGER NOT NULL, stock INTEGER NOT NULL, low_at INTEGER NOT NULL, active INTEGER NOT NULL)');
    await db.execute('CREATE TABLE IF NOT EXISTS pos_tables (id INTEGER PRIMARY KEY, kitchen INTEGER NOT NULL, discount INTEGER NOT NULL, discount_percent INTEGER NOT NULL, discount_reason TEXT NOT NULL)');
    await db.execute('CREATE TABLE IF NOT EXISTS order_lines (id INTEGER PRIMARY KEY AUTOINCREMENT, table_id INTEGER NOT NULL REFERENCES pos_tables(id) ON DELETE CASCADE, position INTEGER NOT NULL, product_id TEXT NOT NULL, name TEXT NOT NULL, price INTEGER NOT NULL, qty INTEGER NOT NULL, sent INTEGER NOT NULL, kitchen INTEGER NOT NULL, UNIQUE(table_id, position))');
    await db.execute('CREATE TABLE IF NOT EXISTS register_sessions (id INTEGER PRIMARY KEY, opened_at TEXT NOT NULL, closed_at TEXT, opening_cash INTEGER NOT NULL, closing_cash INTEGER, expected_cash INTEGER, note TEXT NOT NULL)');
    await db.execute('CREATE TABLE IF NOT EXISTS cash_movements (id INTEGER PRIMARY KEY, session_id INTEGER NOT NULL REFERENCES register_sessions(id) ON DELETE CASCADE, at TEXT NOT NULL, type TEXT NOT NULL, amount INTEGER NOT NULL, note TEXT NOT NULL)');
    await db.execute('CREATE TABLE IF NOT EXISTS sales (position INTEGER PRIMARY KEY, date TEXT NOT NULL, time TEXT NOT NULL, staff TEXT NOT NULL, table_id INTEGER NOT NULL, total INTEGER NOT NULL, discount INTEGER NOT NULL, register_session_id INTEGER REFERENCES register_sessions(id))');
    await db.execute('CREATE TABLE IF NOT EXISTS sale_items (id INTEGER PRIMARY KEY AUTOINCREMENT, sale_position INTEGER NOT NULL REFERENCES sales(position) ON DELETE CASCADE, position INTEGER NOT NULL, product_id TEXT NOT NULL, name TEXT NOT NULL, price INTEGER NOT NULL, qty INTEGER NOT NULL, sent INTEGER NOT NULL, kitchen INTEGER NOT NULL, UNIQUE(sale_position, position))');
    await db.execute('CREATE TABLE IF NOT EXISTS payments (id INTEGER PRIMARY KEY AUTOINCREMENT, sale_position INTEGER NOT NULL REFERENCES sales(position) ON DELETE CASCADE, position INTEGER NOT NULL, method TEXT NOT NULL, amount INTEGER NOT NULL, tendered INTEGER NOT NULL, UNIQUE(sale_position, position))');
    await db.execute('CREATE TABLE IF NOT EXISTS staff (name TEXT PRIMARY KEY, role TEXT NOT NULL, salt TEXT NOT NULL, pin_hash TEXT NOT NULL, active INTEGER NOT NULL)');
    await db.execute('CREATE TABLE IF NOT EXISTS audit (position INTEGER PRIMARY KEY, at TEXT NOT NULL, user TEXT NOT NULL, action TEXT NOT NULL, detail TEXT NOT NULL)');
  }

  int _int(Object? value, [int fallback = 0]) =>
      value is num ? value.toInt() : int.tryParse(value?.toString() ?? '') ?? fallback;
  String _string(Object? value, [String fallback = '']) => value?.toString() ?? fallback;
  bool _bool(Object? value, [bool fallback = false]) =>
      value is bool ? value : value is num ? value != 0 : fallback;

  @override
  Future<String?> read() async {
    final db = await _open();
    final initialized = await db.query('app_meta', columns: ['value'],
        where: 'key = ?', whereArgs: ['initialized'], limit: 1);
    if (initialized.isNotEmpty && initialized.first['value'] == '1') {
      return jsonEncode(await _readNormalized(db));
    }

    final legacyRows = await db.query('app_state', columns: ['payload'],
        where: 'id = ?', whereArgs: [1], limit: 1);
    if (legacyRows.isNotEmpty) return legacyRows.first['payload'] as String;

    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(legacyStoreKey);
  }

  Future<Map<String, dynamic>> _readNormalized(DatabaseExecutor db) async {
    final products = await db.query('products', orderBy: 'rowid');
    final tableRows = await db.query('pos_tables', orderBy: 'id');
    final tables = <Map<String, dynamic>>[];
    for (final table in tableRows) {
      final tableId = _int(table['id']);
      final lines = await db.query('order_lines',
          where: 'table_id = ?', whereArgs: [tableId], orderBy: 'position');
      tables.add({
        'id': tableId,
        'kitchen': _int(table['kitchen']),
        'discount': _int(table['discount']),
        'discountPercent': _int(table['discount_percent']) == 1,
        'discountReason': _string(table['discount_reason']),
        'items': lines.map((line) => {
          'productId': _string(line['product_id']),
          'name': _string(line['name']),
          'price': _int(line['price']),
          'qty': _int(line['qty']),
          'sent': _int(line['sent']) == 1,
          'kitchen': _int(line['kitchen']),
        }).toList(),
      });
    }

    final sessionRows = await db.query('register_sessions', orderBy: 'opened_at');
    final movementRows = await db.query('cash_movements', orderBy: 'at');
    final saleRows = await db.query('sales', orderBy: 'position');
    final sales = <Map<String, dynamic>>[];
    for (final sale in saleRows) {
      final salePosition = _int(sale['position']);
      final items = await db.query('sale_items',
          where: 'sale_position = ?', whereArgs: [salePosition], orderBy: 'position');
      final payments = await db.query('payments',
          where: 'sale_position = ?', whereArgs: [salePosition], orderBy: 'position');
      sales.add({
        'date': _string(sale['date']),
        'time': _string(sale['time']),
        'staff': _string(sale['staff']),
        'table': _int(sale['table_id']),
        'total': _int(sale['total']),
        'discount': _int(sale['discount']),
        'registerSessionId': sale['register_session_id'],
        'items': items.map((line) => {
          'productId': _string(line['product_id']),
          'name': _string(line['name']),
          'price': _int(line['price']),
          'qty': _int(line['qty']),
          'sent': _int(line['sent']) == 1,
          'kitchen': _int(line['kitchen']),
        }).toList(),
        'payments': payments.map((payment) => {
          'method': _string(payment['method']),
          'amount': _int(payment['amount']),
          'tendered': _int(payment['tendered']),
        }).toList(),
      });
    }

    final staffRows = await db.query('staff', orderBy: 'name');
    final auditRows = await db.query('audit', orderBy: 'position');
    final currentUserRows = await db.query('app_meta', columns: ['value'],
        where: 'key = ?', whereArgs: ['currentUser'], limit: 1);
    return {
      'products': products.map((product) => {
        'id': _string(product['id']),
        'category': _string(product['category']),
        'name': _string(product['name']),
        'price': _int(product['price']),
        'stock': _int(product['stock']),
        'lowAt': _int(product['low_at']),
        'active': _int(product['active']) == 1,
      }).toList(),
      'tables': tables,
      'sales': sales,
      'registerSessions': sessionRows.map((session) => {
        'id': _int(session['id']),
        'openedAt': _string(session['opened_at']),
        'closedAt': session['closed_at'],
        'openingCash': _int(session['opening_cash']),
        'closingCash': session['closing_cash'] == null ? null : _int(session['closing_cash']),
        'expectedCash': session['expected_cash'] == null ? null : _int(session['expected_cash']),
        'note': _string(session['note']),
      }).toList(),
      'cashMovements': movementRows.map((movement) => {
        'id': _int(movement['id']),
        'sessionId': _int(movement['session_id']),
        'at': _string(movement['at']),
        'type': _string(movement['type']),
        'amount': _int(movement['amount']),
        'note': _string(movement['note']),
      }).toList(),
      'staff': staffRows.map((member) => {
        'name': _string(member['name']),
        'role': _string(member['role']),
        'salt': _string(member['salt']),
        'pinHash': _string(member['pin_hash']),
        'active': _int(member['active']) == 1,
      }).toList(),
      'audit': auditRows.map((entry) => {
        'at': _string(entry['at']),
        'user': _string(entry['user']),
        'action': _string(entry['action']),
        'detail': _string(entry['detail']),
      }).toList(),
      'currentUser': currentUserRows.isEmpty ? 'Admin' : _string(currentUserRows.first['value'], 'Admin'),
    };
  }

  @override
  Future<void> write(String payload) async {
    final decoded = jsonDecode(payload);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('POS state must be a JSON object');
    }
    final db = await _open();
    await db.transaction((transaction) async {
      await transaction.delete('payments');
      await transaction.delete('sale_items');
      await transaction.delete('sales');
      await transaction.delete('cash_movements');
      await transaction.delete('register_sessions');
      await transaction.delete('order_lines');
      await transaction.delete('pos_tables');
      await transaction.delete('products');
      await transaction.delete('staff');
      await transaction.delete('audit');

      final products = decoded['products'];
      if (products is List) {
        for (final raw in products) {
          final item = Map<String, dynamic>.from(raw as Map);
          await transaction.insert('products', {
            'id': _string(item['id']),
            'category': _string(item['category'], 'Genel'),
            'name': _string(item['name']),
            'price': _int(item['price']),
            'stock': _int(item['stock'], 100),
            'low_at': _int(item['lowAt'], 5),
            'active': _bool(item['active'], true) ? 1 : 0,
          });
        }
      }

      final tables = decoded['tables'];
      if (tables is List) {
        for (final raw in tables) {
          final table = Map<String, dynamic>.from(raw as Map);
          final tableId = _int(table['id']);
          await transaction.insert('pos_tables', {
            'id': tableId,
            'kitchen': _int(table['kitchen']),
            'discount': _int(table['discount']),
            'discount_percent': _bool(table['discountPercent']) ? 1 : 0,
            'discount_reason': _string(table['discountReason']),
          });
          final lines = table['items'];
          if (lines is List) {
            for (var index = 0; index < lines.length; index++) {
              final line = Map<String, dynamic>.from(lines[index] as Map);
              await transaction.insert('order_lines', {
                'table_id': tableId,
                'position': index,
                'product_id': _string(line['productId']),
                'name': _string(line['name']),
                'price': _int(line['price']),
                'qty': _int(line['qty']),
                'sent': _bool(line['sent'], true) ? 1 : 0,
                'kitchen': _int(line['kitchen'], _int(table['kitchen'])),
              });
            }
          }
        }
      }

      final sessions = decoded['registerSessions'];
      if (sessions is List) {
        for (final raw in sessions) {
          final session = Map<String, dynamic>.from(raw as Map);
          await transaction.insert('register_sessions', {
            'id': _int(session['id']),
            'opened_at': _string(session['openedAt']),
            'closed_at': session['closedAt'],
            'opening_cash': _int(session['openingCash']),
            'closing_cash': session['closingCash'] == null ? null : _int(session['closingCash']),
            'expected_cash': session['expectedCash'] == null ? null : _int(session['expectedCash']),
            'note': _string(session['note']),
          });
        }
      }
      final movements = decoded['cashMovements'];
      if (movements is List) {
        for (final raw in movements) {
          final movement = Map<String, dynamic>.from(raw as Map);
          await transaction.insert('cash_movements', {
            'id': _int(movement['id']),
            'session_id': _int(movement['sessionId']),
            'at': _string(movement['at']),
            'type': _string(movement['type']),
            'amount': _int(movement['amount']),
            'note': _string(movement['note']),
          });
        }
      }

      final sales = decoded['sales'];
      if (sales is List) {
        for (var index = 0; index < sales.length; index++) {
          final sale = Map<String, dynamic>.from(sales[index] as Map);
          await transaction.insert('sales', {
            'position': index,
            'date': _string(sale['date']),
            'time': _string(sale['time']),
            'staff': _string(sale['staff'], 'Admin'),
            'table_id': _int(sale['table']),
            'total': _int(sale['total']),
            'discount': _int(sale['discount']),
            'register_session_id': sale['registerSessionId'],
          });
          final items = sale['items'];
          if (items is List) {
            for (var itemIndex = 0; itemIndex < items.length; itemIndex++) {
              final line = Map<String, dynamic>.from(items[itemIndex] as Map);
              await transaction.insert('sale_items', {
                'sale_position': index,
                'position': itemIndex,
                'product_id': _string(line['productId']),
                'name': _string(line['name']),
                'price': _int(line['price']),
                'qty': _int(line['qty']),
                'sent': _bool(line['sent'], true) ? 1 : 0,
                'kitchen': _int(line['kitchen']),
              });
            }
          }
          final payments = sale['payments'];
          if (payments is List) {
            for (var paymentIndex = 0; paymentIndex < payments.length; paymentIndex++) {
              final payment = Map<String, dynamic>.from(payments[paymentIndex] as Map);
              await transaction.insert('payments', {
                'sale_position': index,
                'position': paymentIndex,
                'method': _string(payment['method'], 'Nakit'),
                'amount': _int(payment['amount']),
                'tendered': _int(payment['tendered'], _int(payment['amount'])),
              });
            }
          }
        }
      }

      final staff = decoded['staff'];
      if (staff is List) {
        for (final raw in staff) {
          final member = Map<String, dynamic>.from(raw as Map);
          await transaction.insert('staff', {
            'name': _string(member['name'], 'Personel'),
            'role': _string(member['role'], 'Garson'),
            'salt': _string(member['salt']),
            'pin_hash': _string(member['pinHash']),
            'active': _bool(member['active'], true) ? 1 : 0,
          });
        }
      }

      final audit = decoded['audit'];
      if (audit is List) {
        for (var index = 0; index < audit.length; index++) {
          final entry = Map<String, dynamic>.from(audit[index] as Map);
          await transaction.insert('audit', {
            'position': index,
            'at': _string(entry['at']),
            'user': _string(entry['user']),
            'action': _string(entry['action']),
            'detail': _string(entry['detail']),
          });
        }
      }

      await transaction.insert('app_meta', {'key': 'initialized', 'value': '1'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await transaction.insert('app_meta', {
        'key': 'currentUser',
        'value': _string(decoded['currentUser'], 'Admin'),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await transaction.delete('app_state', where: 'id = ?', whereArgs: [1]);
    });

    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(legacyStoreKey);
    try {
      await _writeRotatingBackup(payload);
    } catch (_) {
      // SQLite has committed; a backup failure must not roll back the live state.
    }
  }

  Future<Directory> _backupDirectory() async {
    final root = _backupDirectoryPath ?? (await getApplicationDocumentsDirectory()).path;
    final directory = Directory(path.join(root, 'backups'));
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  Future<void> _writeRotatingBackup(String payload) async {
    final directory = await _backupDirectory();
    final date = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    final file = File(path.join(directory.path, 'restaurant-pos-$date.json'));
    await file.writeAsString(payload, flush: true);
    final backups = await directory.list()
        .where((entry) => entry is File && isDailyBackupFileName(path.basename(entry.path)))
        .cast<File>().toList();
    backups.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    for (final old in backups.skip(7)) {
      await old.delete();
    }
  }

  @override
  Future<void> backupBeforeRestore(String payload) async {
    final directory = await _backupDirectory();
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    final file = File(path.join(directory.path, 'restaurant-pos-pre-restore-$stamp.json'));
    await file.writeAsString(payload, flush: true);
  }

  @override
  Future<List<BackupFile>> listBackups() async {
    final directory = await _backupDirectory();
    final files = await directory.list()
        .where((entry) => entry is File && isRestorableBackupFileName(path.basename(entry.path)))
        .cast<File>().toList();
    final result = <BackupFile>[];
    for (final file in files) {
      result.add(BackupFile(path.basename(file.path), await file.lastModified(), await file.length()));
    }
    result.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return result;
  }

  @override
  Future<String?> readBackup(String name) async {
    if (path.basename(name) != name || !isRestorableBackupFileName(name)) return null;
    final file = File(path.join((await _backupDirectory()).path, name));
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  @override
  Future<void> backupCorrupt(String payload) async {
    final directory = await _backupDirectory();
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    await File(path.join(directory.path, 'restaurant-pos-corrupt-$stamp.json'))
        .writeAsString(payload, flush: true);
    final db = await _open();
    await db.delete('app_state', where: 'id = ?', whereArgs: [1]);
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}

class MemoryStoreRepository implements StoreRepository {
  MemoryStoreRepository({this.value});
  String? value;
  String? corruptBackup;
  final Map<String, String> backupFiles = {};

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String payload) async {
    value = payload;
  }

  @override
  Future<void> backupBeforeRestore(String payload) async {
    backupFiles['restaurant-pos-pre-restore-${DateTime.now().microsecondsSinceEpoch}.json'] = payload;
  }

  @override
  Future<List<BackupFile>> listBackups() async => backupFiles.entries
      .map((entry) => BackupFile(entry.key, DateTime.fromMicrosecondsSinceEpoch(
          int.tryParse(entry.key.split('-').last.replaceAll('.json', '')) ?? 0),
          entry.value.length))
      .toList()
    ..sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));

  @override
  Future<String?> readBackup(String name) async => backupFiles[name];

  @override
  Future<void> backupCorrupt(String payload) async {
    corruptBackup = payload;
    value = null;
  }
}
