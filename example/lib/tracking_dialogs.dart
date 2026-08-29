import 'package:flutter/material.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';

class RouteIdentifierDialog extends StatefulWidget {
  const RouteIdentifierDialog({super.key});

  @override
  State<RouteIdentifierDialog> createState() => _RouteIdentifierDialogState();
}

class _RouteIdentifierDialogState extends State<RouteIdentifierDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Route ID'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      decoration: const InputDecoration(
        hintText: 'Morning delivery route',
        helperText:
            'Whitespace is converted to underscores; a UTC suffix is added.',
      ),
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => _submit(),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _controller.text.trim().isEmpty ? null : _submit,
        child: const Text('Start'),
      ),
    ],
  );

  void _submit() {
    final value = _controller.text.trim();
    if (value.isNotEmpty) Navigator.pop(context, value);
  }
}

class ExportNameDialog extends StatefulWidget {
  const ExportNameDialog({
    super.key,
    required this.format,
    required this.initialFileName,
  });

  final TrackExportFormat format;
  final String initialFileName;

  @override
  State<ExportNameDialog> createState() => _ExportNameDialogState();
}

class _ExportNameDialogState extends State<ExportNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialFileName,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Export ${widget.format.name}'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      decoration: const InputDecoration(
        labelText: 'File name',
        helperText: 'Unsafe characters are normalized by the package.',
      ),
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => _submit(),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _controller.text.trim().isEmpty ? null : _submit,
        child: const Text('Export'),
      ),
    ],
  );

  void _submit() {
    final value = _controller.text.trim();
    if (value.isNotEmpty) Navigator.pop(context, value);
  }
}
