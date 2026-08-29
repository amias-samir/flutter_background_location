import 'dart:io';

const _path = 'tool/quality/requirements.yaml';
const _errorCodePath = 'tool/quality/error_codes.yaml';
const _ignoredMaintainerDocsPrefix = 'plugin_documents/';

void main() {
  final file = File(_path);
  if (!file.existsSync()) {
    stderr.writeln('Missing $_path');
    exitCode = 1;
    return;
  }

  final lines = file.readAsLinesSync();
  final ids = <String>{};
  final duplicates = <String>{};
  final idPattern =
      RegExp(r'^\s*-\s+id:\s+([A-Z][0-9]-(?:[A-Z0-9]+|[0-9]{2}))\s*$');
  var hasCompatibility = false;
  var hasChangeClassifications = false;

  for (final line in lines) {
    if (line.trim() == 'compatibility:') {
      hasCompatibility = true;
    }
    if (line.trim() == 'change_classifications:') {
      hasChangeClassifications = true;
    }
    final match = idPattern.firstMatch(line);
    if (match == null) {
      continue;
    }
    final id = match.group(1)!;
    if (!ids.add(id)) {
      duplicates.add(id);
    }
  }

  final errors = <String>[];
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.startsWith('- $_ignoredMaintainerDocsPrefix')) {
      errors.add(
        'Evidence must be available in a clean checkout; replace ignored '
        '${trimmed.substring(2)} with a tracked package artifact.',
      );
    }
  }
  if (!hasCompatibility) {
    errors.add('Missing compatibility section.');
  }
  if (!hasChangeClassifications) {
    errors.add('Missing change_classifications section.');
  }
  if (ids.length != 52) {
    errors.add('Expected 52 work-package IDs, found ${ids.length}.');
  }
  if (duplicates.isNotEmpty) {
    errors.add('Duplicate work-package IDs: ${duplicates.join(', ')}.');
  }

  final errorCodeFile = File(_errorCodePath);
  if (!errorCodeFile.existsSync()) {
    errors.add('Missing $_errorCodePath');
  } else {
    final codePattern = RegExp(r'^\s*-\s+code:\s+([a-z][a-z0-9_]+)\s*$');
    final codes = <String>{};
    final duplicateCodes = <String>{};
    for (final line in errorCodeFile.readAsLinesSync()) {
      final match = codePattern.firstMatch(line);
      if (match == null) continue;
      final code = match.group(1)!;
      if (!codes.add(code)) duplicateCodes.add(code);
    }
    if (codes.isEmpty) {
      errors.add('No stable error codes found in $_errorCodePath.');
    }
    if (duplicateCodes.isNotEmpty) {
      errors.add('Duplicate error codes: ${duplicateCodes.join(', ')}.');
    }
  }

  if (errors.isNotEmpty) {
    for (final error in errors) {
      stderr.writeln(error);
    }
    exitCode = 1;
    return;
  }

  stdout.writeln('Validated $_path with ${ids.length} work-package IDs.');
}
