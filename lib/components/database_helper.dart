import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  factory DatabaseHelper() => _instance;
  static Database? _database;

  DatabaseHelper._internal();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'downloads.db');
    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE downloads (
            id TEXT PRIMARY KEY,
            filePath TEXT,
            fileName TEXT,
            status TEXT
          )
        ''');
      },
    );
  }

  Future<void> insertDownload(String id, String filePath, String fileName, String status) async {
    final db = await database;
    await db.insert(
      'downloads',
      {
        'id': id,
        'filePath': filePath,
        'fileName': fileName,
        'status': status,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}