// Generates the Windows executable icon committed at
// windows/runner/resources/app_icon.ico (referenced by windows/runner/Runner.rc).
// Run with: dart run tool/gen_app_icon.dart
//
// Workflow: design/app-icon.svg is the editable vector master; it is exported
// once to design/app-icon.png (lossless 256x256 RGBA, committed). This script
// only packages that raster: the 256 frame is the PNG unchanged and every
// smaller frame is a cubic downscale of it, so the ICO can be regenerated
// byte-for-byte from the committed PNG. It does not read the SVG.
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart';

const masterPath = 'design/app-icon.png';
const icoPath = 'windows/runner/resources/app_icon.ico';

/// Sizes Windows picks from for Explorer, taskbar, title bar and Alt+Tab.
const icoSizes = [16, 24, 32, 48, 64, 128, 256];

/// Encodes the seven-frame ICO from the 256x256 [master].
Uint8List buildIco(Image master) {
  final frames = [
    for (final size in icoSizes)
      size == master.width
          ? master
          : copyResize(
              master,
              width: size,
              height: size,
              interpolation: Interpolation.cubic,
            ),
  ];
  return IcoEncoder().encodeImages(frames);
}

void main() {
  final master = decodePng(File(masterPath).readAsBytesSync())!;
  File(icoPath).writeAsBytesSync(buildIco(master));
  stdout.writeln('$icoPath (${icoSizes.join(', ')})');
}
