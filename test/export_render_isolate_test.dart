import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'test_support.dart';

// FLT-26: a long route is encoded on a background isolate; the output must
// be byte-identical to encoding it inline, and still parse.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a long route renders identically on a background isolate', () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final trackId = await harness.createActiveTrack(trackId: 'long');
    for (var i = 0; i < 2100; i += 1) {
      await harness.append(
        trackId: trackId,
        latitude: 10 + i * 0.00005,
        longitude: 20 + (i.isEven ? 0.00001 : -0.00001),
        capturedAt: harness.now.add(Duration(seconds: 5 * i)),
      );
    }
    await harness.repository.completeTrack(trackId, reason: 'finished');
    final bundle = await harness.repository.loadTrackBundle(trackId);
    final report = const RouteGeometryAssembler().assemble(
      sourceParts: bundle.segments.map(
        (source) => RouteGeometrySourcePart(
          legNumber: 1,
          segment: source.segment,
          points: source.points,
        ),
      ),
      continuity: RouteGeometryContinuity.preserveEvidenceSegments,
    );
    final service = TrackExportService(
      repository: harness.repository,
      fileWriter: _NoWriter(),
    );
    const options = TrackExportOptions();
    for (final format in TrackExportFormat.values) {
      final inline = service.renderAssembledBundle(
        bundle: bundle,
        format: format,
        options: options,
        report: report,
      );
      final background = await TrackExportService.renderAssembledAsync(
        bundle: bundle,
        format: format,
        options: options,
        report: report,
      );
      expect(background.contents, inline.contents, reason: format.name);
      expect(background.fileName, inline.fileName);
      expect(background.mimeType, inline.mimeType);
      if (format != TrackExportFormat.geoJson) {
        // Independent parse: the dropped re-parse was only a check.
        expect(() => XmlDocument.parse(background.contents), returnsNormally);
      }
    }
    await harness.repository.close();
  });
}

final class _NoWriter implements ExportFileWriter {
  @override
  Future<void> delete(String path) async {}

  @override
  Future<String> write({
    required String fileName,
    required String contents,
    String? mimeType,
  }) async =>
      fileName;
}
