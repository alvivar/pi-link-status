// Generates the tray icons committed under assets/tray/.
// Run with: dart run tool/gen_icons.dart
//
// Each fleet state gets a filled circle on a transparent background: a 256x256
// PNG for macOS/Linux and a multi-size ICO for Windows. The generated files are
// committed, so building the app never requires this script.
import 'dart:io';

import 'package:image/image.dart';

/// Tray colors per fleet state (see PLAN.md, "Diseño / Tray").
const _colors = <String, int>{
  'offline': 0x9E9E9E,
  'idle': 0x43A047,
  'busy': 0x1E88E5,
  'compacting': 0xFFB300,
};

/// Sizes Windows picks from depending on DPI and surface.
const _icoSizes = [16, 20, 24, 32, 48, 64, 256];

const _size = 256;
const _radius = 112; // leaves a 16px margin, so the disc never touches the edge.

void main() {
  final dir = Directory('assets/tray')..createSync(recursive: true);

  for (final MapEntry(key: state, value: rgb) in _colors.entries) {
    final master = Image(width: _size, height: _size, numChannels: 4);
    fillCircle(
      master,
      x: _size ~/ 2,
      y: _size ~/ 2,
      radius: _radius,
      color: ColorRgba8(rgb >> 16 & 0xFF, rgb >> 8 & 0xFF, rgb & 0xFF, 0xFF),
      antialias: true,
    );

    final png = File('${dir.path}/$state.png')
      ..writeAsBytesSync(encodePng(master));

    final frames = [
      for (final size in _icoSizes)
        size == _size
            ? master
            : copyResize(
                master,
                width: size,
                height: size,
                interpolation: Interpolation.cubic,
              ),
    ];
    final ico = File('${dir.path}/$state.ico')
      ..writeAsBytesSync(IcoEncoder().encodeImages(frames));

    stdout.writeln('${png.path} · ${ico.path} (${_icoSizes.join(', ')})');
  }
}
