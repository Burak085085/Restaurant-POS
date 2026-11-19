import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String legacyStoreKey = 'restaurant_pos_v2';

abstract class StoreRepository {
  Future<String?> read();
  Future<void> write(String payload);
  Future<void> backupCorrupt(String payload);
}

class SqliteStoreRepository implements StoreRepository {
  Database? _database;

  Future<Database> _open() async {
    if (_database != null) return _database!;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final directory = await getApplicationDocumentsDirectory();
    _database = await openDatabase(
      path.join(directory.path, 'restaurant_pos.sqlite3'),
      version: 1,
      onConfigure: (db) async {
        await db.execute('PRAGMA journal_mode = WAL');
        await db.execute('PRAGMA synchronous = FULL');
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await db.execute('CREATE TABLE app_state (id INTEGER PRIMARY KEY CHECK (id = 1), payload TEXT NOT NULL, updated_at TEXT NOT NULL)');
      },
    );
    return _database!;
  }

  @override
  Future<String?> read() async {
    final db = await _open();
    final rows = await db.query('app_state', columns: ['payload'], where: 'id = ?', whereArgs: [1], limit: 1);
    if (rows.isNotEmpty) return rows.first['payload'] as String;
    final preferences = await SharedPreferences.getInstance();
    final legacy = preferences.getString(legacyStoreKey);
    if (legacy == null) return null;
    await write(legacy);
    await preferences.remove(legacyStoreKey);
    return legacy;
  }

  @override
  Future<void> write(String payload) async {
    final db = await _open();
    await db.transaction((transaction) async {
      await transaction.insert('app_state', {
        'id': 1,
        'payload': payload,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    try {
      await _writeRotatingBackup(payload);
    } catch (_) {
      // The committed SQLite transaction remains authoritative.
    }
  }

  Future<Directory> _backupDirectory() async {
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory(path.join(documents.path, 'backups'));
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  Future<void> _writeRotatingBackup(String payload) async {
    final directory = await _backupDirectory();
    final date = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    final file = File(path.join(directory.path, 'restaurant-pos-$date.json'));
    await file.writeAsString(payload, flush: true);
    final backups = await directory.list()
        .where((entry) => entry is File && path.basename(entry.path).startsWith('restaurant-pos-'))
        .cast<File>().toList();
    backups.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    for (final old in backups.skip(7)) {
      await old.delete();
    }
  }

  @override
  Future<void> backupCorrupt(String payload) async {
    final directory = await _backupDirectory();
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    await File(path.join(directory.path, 'restaurant-pos-corrupt-$stamp.json')).writeAsString(payload, flush: true);
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

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String payload) async {
    value = payload;
  }

  @override
  Future<void> backupCorrupt(String payload) async {
    corruptBackup = payload;
    value = null;
  }
}
