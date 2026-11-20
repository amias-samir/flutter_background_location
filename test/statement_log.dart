import 'package:sqflite_common/sqflite_logger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Records every statement a repository runs, so a test can prove a read
/// writes nothing and binds a bounded number of arguments.
final class StatementLog {
  /// Statements run inside batches, counted one by one.
  var batchedStatements = 0;

  final statements = <(String, int)>[];
  var batches = 0;

  DatabaseFactory factory() {
    sqfliteFfiInit();
    // Test-only statement recorder; the API is marked experimental.
    // ignore: experimental_member_use
    return SqfliteDatabaseFactoryLogger(
      databaseFactoryFfi,
      options: SqfliteLoggerOptions(
        type: SqfliteDatabaseFactoryLoggerType.all,
        log: (event) {
          switch (event) {
            case SqfliteLoggerSqlEvent(:final sql, :final arguments):
              statements.add(
                (sql, arguments is List ? arguments.length : 0),
              );
            case SqfliteLoggerBatchEvent(:final operations):
              batches += 1;
              batchedStatements += operations.length;
            default:
          }
        },
      ),
    );
  }

  void clear() {
    statements.clear();
    batches = 0;
    batchedStatements = 0;
  }

  /// Every statement SQLite ran, single or batched.
  int get totalStatements => statements.length + batchedStatements;

  /// Platform-channel round trips: one per statement or batch.
  int get roundTrips => statements.length + batches;

  static final _write = RegExp(
    r'^\s*(INSERT|UPDATE|DELETE|REPLACE|BEGIN|COMMIT|CREATE|DROP|ALTER)\b',
    caseSensitive: false,
  );

  List<String> get writes => <String>[
        for (final (sql, _) in statements)
          if (_write.hasMatch(sql)) sql,
      ];

  int get maxArguments => statements.fold(
        0,
        (max, statement) => statement.$2 > max ? statement.$2 : max,
      );
}
