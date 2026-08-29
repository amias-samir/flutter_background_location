import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path_util;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../domain/export_models.dart';
import '../domain/native_tracking_protocol.dart';
import '../domain/tracking_error.dart';
import '../domain/tracking_start.dart';
import '../storage/track_repository.dart';
import 'incremental_track_export.dart';
import 'track_export_service.dart';

typedef ExportDirectoryProvider = Future<Directory> Function();

/// Owner-bound, bounded-memory V2 route export service.
///
/// Android writes incrementally to public Downloads through MediaStore (or an
/// atomic pre-Q file). Other platforms write an atomic local file. The result
/// never presents a content URI as a filesystem path.
final class TrackExportServiceV2
    implements TrackingExportController, TrackingManagedExportController {
  TrackExportServiceV2({
    required this.repository,
    required this.owner,
    this.directoryName = 'flutter_background_location',
    MethodChannel? methodChannel,
    ExportDirectoryProvider? exportDirectoryProvider,
    ExportDirectoryProvider? shareCacheDirectoryProvider,
    bool Function()? isOwnerScopeCurrent,
    bool? useAndroidNativeDestination,
    this.staleShareFileAge = const Duration(hours: 24),
  })  : _methodChannel =
            methodChannel ?? const MethodChannel(_methodChannelName),
        _exportDirectoryProvider =
            exportDirectoryProvider ?? _defaultExportDirectory,
        _shareCacheDirectoryProvider =
            shareCacheDirectoryProvider ?? _defaultShareCacheDirectory,
        _isOwnerScopeCurrent = isOwnerScopeCurrent ?? _alwaysCurrent,
        _useAndroidNativeDestination =
            useAndroidNativeDestination ?? Platform.isAndroid;

  static const String _methodChannelName =
      'flutter_background_location/methods';
  static const int _copyChunkBytes = 1024 * 1024;

  final TrackRepository repository;
  final TrackingOwner owner;
  final String directoryName;
  final MethodChannel _methodChannel;
  final ExportDirectoryProvider _exportDirectoryProvider;
  final ExportDirectoryProvider _shareCacheDirectoryProvider;
  final bool Function() _isOwnerScopeCurrent;
  final bool _useAndroidNativeDestination;
  final Duration staleShareFileAge;

  static bool _alwaysCurrent() => true;

  @override
  Future<TrackExportOperation> exportTrackV2(TrackExportRequest request) async {
    if (!_isOwnerScopeCurrent()) {
      throw const TrackingOwnershipException(
        code: 'owner_scope_changed',
        message: 'The owner scope changed before export started.',
      );
    }

    final IncrementalExportSinkFactory sinkFactory;
    if (_useAndroidNativeDestination) {
      final protocol = await _nativeProtocol();
      if (!protocol.supports(NativeTrackingCapabilities.streamingExportV2)) {
        throw const TrackingExportException(
          code: 'native_protocol_upgrade_required',
          message:
              'The installed Android plugin cannot create safe V2 exports.',
        );
      }
      sinkFactory = () => _AndroidDownloadsV2Sink(
            channel: _methodChannel,
            directoryName: directoryName,
          );
    } else {
      final root = await _exportDirectoryProvider();
      final directory = Directory(path_util.join(root.path, directoryName));
      sinkFactory = () => FileSystemIncrementalExportSink(
            directory.path,
            userVisible: true,
          );
    }

    return IncrementalTrackExportService(
      repository: repository,
      sinkFactory: sinkFactory,
    ).start(
      owner: owner,
      trackId: request.trackId,
      format: request.format,
      options: request.options,
      fileName: request.fileName,
      isOwnerScopeCurrent: _isOwnerScopeCurrent,
    );
  }

  @override
  Future<PreparedTrackShareFile> prepareExportForSharing(
    TrackExportResultV2 result,
  ) async {
    if (!_isOwnerScopeCurrent()) {
      throw const TrackingOwnershipException(
        code: 'owner_scope_changed',
        message: 'The owner scope changed before share preparation.',
      );
    }
    final track = await repository.getTrack(result.trackId);
    if (track == null || !owner.owns(track)) {
      throw const TrackingOwnershipException(
        code: 'track_not_found_in_owner_scope',
        message: 'The route is not available in the current owner scope.',
      );
    }
    if (repository is! ManagedExportRepository) {
      throw const TrackingStorageException(
        code: 'capability_unsupported',
        message: 'This repository does not support managed export inventory.',
      );
    }
    final inventory = await (repository as ManagedExportRepository)
        .getManagedExport(owner: owner, exportId: result.managedExportId);
    if (inventory == null ||
        inventory.trackId != result.trackId ||
        inventory.state != ManagedExportState.committed ||
        !_sameDestination(inventory.destination, result.destination)) {
      throw const TrackingExportException(
        code: 'managed_export_not_found',
        message: 'The export is not present in the current owner inventory.',
      );
    }

    final cacheRoot = await _shareCacheDirectoryProvider();
    final cacheDirectory = Directory(
      path_util.join(cacheRoot.path, 'flutter_background_location_share'),
    );
    await cacheDirectory.create(recursive: true);
    await _sweepStaleShareFiles(cacheDirectory);
    final safeName = sanitizeExportFileName(result.destination.displayName);
    final destination = File(
      path_util.join(
        cacheDirectory.path,
        '${const Uuid().v4()}_$safeName',
      ),
    );

    try {
      final sourcePath = result.destination.localFilePath;
      if (sourcePath != null) {
        await _copyLocalFile(File(sourcePath), destination);
      } else {
        final contentUri = result.destination.contentUri;
        if (!_useAndroidNativeDestination || contentUri == null) {
          throw const TrackingExportException(
            code: 'export_destination_unreadable',
            message: 'The export destination cannot be copied for sharing.',
          );
        }
        final copied = await _methodChannel.invokeMethod<Object?>(
          'copyExportToCacheV2',
          <String, Object?>{
            'contentUri': contentUri.toString(),
            'destinationPath': destination.path,
          },
        );
        if (copied != true || !await destination.exists()) {
          throw const TrackingExportException(
            code: 'share_copy_failed',
            message: 'The Android export could not be copied for sharing.',
          );
        }
      }
      if (!_isOwnerScopeCurrent()) {
        throw const TrackingOwnershipException(
          code: 'owner_scope_changed',
          message: 'The owner scope changed during share preparation.',
        );
      }
      return _PreparedTrackShareFile(
        file: destination,
        allowedRoot: cacheDirectory.path,
        mimeType: result.destination.mimeType,
        displayName: safeName,
      );
    } on Object {
      if (await destination.exists()) await destination.delete();
      rethrow;
    }
  }

  @override
  Future<List<ManagedTrackExport>> listManagedExports(String trackId) async {
    final track = await repository.getTrack(trackId);
    if (track == null || !owner.owns(track)) {
      throw const TrackingOwnershipException(
        code: 'track_not_found_in_owner_scope',
        message: 'The route is not available in the current owner scope.',
      );
    }
    final inventory = _inventory;
    final records = await inventory.listManagedExports(
      owner: owner,
      trackId: trackId,
    );
    return records
        .map(
          (record) => ManagedTrackExport(
            id: record.id,
            trackId: record.trackId,
            format: record.format,
            state: record.state.name,
            destination: record.destination,
            createdAt: record.createdAt,
            deletedAt: record.deletedAt,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<ManagedExportDeletionReport> deleteManagedExport(
    String exportId,
  ) async {
    final inventory = _inventory;
    final record = await inventory.getManagedExport(
      owner: owner,
      exportId: exportId,
    );
    if (record == null) {
      throw const TrackingOwnershipException(
        code: 'managed_export_not_found_in_owner_scope',
        message: 'The export is not available in this owner scope.',
      );
    }
    if (record.state == ManagedExportState.deleted) {
      return ManagedExportDeletionReport(
        exportId: exportId,
        status: 'already_deleted',
        artifactRemoved: false,
      );
    }
    if (record.state != ManagedExportState.committed ||
        record.destination == null) {
      throw const TrackingExportException(
        code: 'managed_export_not_committed',
        message: 'Only a committed managed export can be deleted.',
      );
    }

    final destination = record.destination!;
    final bool removed;
    if (_useAndroidNativeDestination) {
      removed = await _methodChannel.invokeMethod<bool>(
            'deleteExportDestinationV2',
            <String, Object?>{
              if (destination.contentUri case final uri?)
                'contentUri': uri.toString(),
              if (destination.localFilePath case final filePath?)
                'localFilePath': filePath,
            },
          ) ??
          false;
    } else {
      final filePath = destination.localFilePath;
      if (filePath == null) {
        throw const TrackingExportException(
          code: 'export_destination_unreadable',
          message: 'This export destination cannot be deleted locally.',
        );
      }
      final root = Directory(
        path_util.join((await _exportDirectoryProvider()).path, directoryName),
      );
      final normalizedRoot = path_util.normalize(path_util.absolute(root.path));
      final candidate = path_util.normalize(path_util.absolute(filePath));
      if (!path_util.isWithin(normalizedRoot, candidate)) {
        throw const TrackingExportException(
          code: 'unsafe_export_path',
          message: 'The managed export path is outside the export directory.',
        );
      }
      final file = File(candidate);
      removed = await file.exists();
      if (removed) await file.delete();
    }
    await inventory.markManagedExportDeleted(
      owner: owner,
      exportId: exportId,
    );
    return ManagedExportDeletionReport(
      exportId: exportId,
      status: removed ? 'deleted' : 'already_missing',
      artifactRemoved: removed,
    );
  }

  ManagedExportRepository get _inventory {
    final store = repository;
    if (store is ManagedExportRepository) {
      return store as ManagedExportRepository;
    }
    throw const TrackingStorageException(
      code: 'capability_unsupported',
      message: 'This repository does not support managed export inventory.',
    );
  }

  Future<NativeTrackingProtocol> _nativeProtocol() async {
    try {
      final raw = await _methodChannel.invokeMethod<Object?>('getProtocolInfo');
      final map = raw is Map<Object?, Object?>
          ? raw
          : raw is Map
              ? raw.cast<Object?, Object?>()
              : const <Object?, Object?>{};
      return NativeTrackingProtocol.fromMap(map);
    } on MissingPluginException {
      return NativeTrackingProtocol.legacy();
    }
  }

  Future<void> _sweepStaleShareFiles(Directory directory) async {
    final threshold = DateTime.now().toUtc().subtract(staleShareFileAge);
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      try {
        final modified = (await entity.stat()).modified.toUtc();
        if (modified.isBefore(threshold)) await entity.delete();
      } on FileSystemException {
        // Best-effort cleanup must not prevent a new share operation.
      }
    }
  }

  static Future<void> _copyLocalFile(File source, File destination) async {
    if (!await source.exists()) {
      throw const TrackingExportException(
        code: 'export_destination_unreadable',
        message: 'The exported file is no longer readable.',
      );
    }
    final input = await source.open();
    final output = await destination.open(mode: FileMode.write);
    try {
      while (true) {
        final bytes = await input.read(_copyChunkBytes);
        if (bytes.isEmpty) break;
        await output.writeFrom(bytes);
      }
      await output.flush();
    } finally {
      await input.close();
      await output.close();
    }
  }

  static bool _sameDestination(
    TrackExportDestination? first,
    TrackExportDestination second,
  ) =>
      first != null &&
      first.displayName == second.displayName &&
      first.mimeType == second.mimeType &&
      first.contentUri == second.contentUri &&
      first.localFilePath == second.localFilePath;

  static Future<Directory> _defaultExportDirectory() async =>
      await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();

  static Future<Directory> _defaultShareCacheDirectory() =>
      getTemporaryDirectory();
}

final class _AndroidDownloadsV2Sink implements IncrementalExportSink {
  _AndroidDownloadsV2Sink({
    required this.channel,
    required this.directoryName,
  });

  static const int _maximumChunkBytes = 1024 * 1024;
  final MethodChannel channel;
  final String directoryName;
  String? _handleId;
  bool _committed = false;
  TrackExportDestination? _destination;
  IncrementalExportDescriptor? _descriptor;

  @override
  Future<void> open(IncrementalExportDescriptor descriptor) async {
    _descriptor = descriptor;
    try {
      final raw = await channel.invokeMethod<Object?>(
        'beginExportToDownloadsV2',
        <String, Object?>{
          'directoryName': directoryName,
          'fileName': sanitizeExportFileName(descriptor.fileName),
          'mimeType': descriptor.mimeType,
        },
      );
      final map = _asMap(raw);
      final handleId = map['handleId'] as String?;
      if (handleId == null || handleId.isEmpty) {
        throw const FormatException('Native export handle is missing.');
      }
      _handleId = handleId;
    } on PlatformException catch (error) {
      throw _nativeExportError(error);
    }
  }

  @override
  Future<void> addUtf8(List<int> bytes) async {
    final handleId = _requireOpenHandle();
    try {
      for (var offset = 0;
          offset < bytes.length;
          offset += _maximumChunkBytes) {
        final end = (offset + _maximumChunkBytes).clamp(0, bytes.length);
        await channel.invokeMethod<Object?>(
          'appendExportToDownloadsV2',
          <String, Object?>{
            'handleId': handleId,
            'bytes': Uint8List.fromList(bytes.sublist(offset, end)),
          },
        );
      }
    } on PlatformException catch (error) {
      throw _nativeExportError(error);
    }
  }

  @override
  Future<TrackExportDestination> commit() async {
    final handleId = _requireOpenHandle();
    try {
      final raw = await channel.invokeMethod<Object?>(
        'commitExportToDownloadsV2',
        <String, Object?>{'handleId': handleId},
      );
      final destination = TrackExportDestination.fromMap(_asMap(raw));
      final descriptor = _descriptor;
      if (descriptor == null || destination.mimeType != descriptor.mimeType) {
        throw const FormatException(
          'Native export destination metadata does not match the request.',
        );
      }
      _committed = true;
      _destination = destination;
      return destination;
    } on PlatformException catch (error) {
      throw _nativeExportError(error);
    }
  }

  @override
  Future<void> abort() async {
    final handleId = _handleId;
    _handleId = null;
    if (handleId == null) return;
    try {
      await channel.invokeMethod<Object?>(
        'abortExportToDownloadsV2',
        <String, Object?>{
          'handleId': handleId,
          'deleteCommitted': _committed,
          if (_destination?.contentUri case final contentUri?)
            'contentUri': contentUri.toString(),
          if (_destination?.localFilePath case final localFilePath?)
            'localFilePath': localFilePath,
        },
      );
    } on MissingPluginException {
      // A detached engine cannot retain an open Dart operation.
    }
  }

  String _requireOpenHandle() {
    final value = _handleId;
    if (value == null) {
      throw StateError('The Android export sink is not open.');
    }
    return value;
  }

  static Map<Object?, Object?> _asMap(Object? value) {
    if (value is Map<Object?, Object?>) return value;
    if (value is Map) return value.cast<Object?, Object?>();
    throw const FormatException('Native export response must be a map.');
  }

  static TrackingExportException _nativeExportError(PlatformException error) =>
      TrackingExportException(
        code: error.code,
        message: error.message ?? 'The native export operation failed.',
        cause: error.details,
      );
}

final class _PreparedTrackShareFile implements PreparedTrackShareFile {
  const _PreparedTrackShareFile({
    required this.file,
    required this.allowedRoot,
    required this.mimeType,
    required this.displayName,
  });

  final File file;
  final String allowedRoot;

  @override
  String get path => file.path;

  @override
  final String mimeType;

  @override
  final String displayName;

  @override
  Future<void> delete() async {
    final root = path_util.normalize(path_util.absolute(allowedRoot));
    final candidate = path_util.normalize(path_util.absolute(file.path));
    if (!path_util.isWithin(root, candidate)) {
      throw const TrackingExportException(
        code: 'unsafe_share_cache_path',
        message: 'The prepared share file is outside the managed cache.',
      );
    }
    if (await file.exists()) await file.delete();
  }
}
