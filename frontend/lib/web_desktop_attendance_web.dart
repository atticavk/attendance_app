import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

bool hasFinePointerForAttendance() {
  return html.window.matchMedia('(hover: hover) and (pointer: fine)').matches;
}

bool hasTouchInputForAttendance() {
  return (html.window.navigator.maxTouchPoints ?? 0) > 0 ||
      html.window.matchMedia('(any-pointer: coarse)').matches ||
      html.window.matchMedia('(pointer: coarse)').matches;
}

void clearFreshLoginBrowserStorage() {
  html.window.localStorage.clear();
  html.window.sessionStorage.clear();
}

Future<Uint8List?> capturePhotoWithBrowserCamera({
  String facingMode = 'user',
}) async {
  if (html.window.navigator.mediaDevices == null) {
    throw StateError('Camera access is not supported in this browser.');
  }

  final completer = Completer<Uint8List?>();
  html.MediaStream? stream;

  final overlay = html.DivElement()
    ..style.position = 'fixed'
    ..style.left = '0'
    ..style.top = '0'
    ..style.right = '0'
    ..style.bottom = '0'
    ..style.zIndex = '2147483647'
    ..style.background = 'rgba(0, 0, 0, 0.94)'
    ..style.display = 'flex'
    ..style.flexDirection = 'column'
    ..style.alignItems = 'center'
    ..style.justifyContent = 'center'
    ..style.padding = '20px'
    ..style.boxSizing = 'border-box';

  final title = html.DivElement()
    ..text = 'Camera Capture'
    ..style.color = '#ffffff'
    ..style.fontSize = '20px'
    ..style.fontWeight = '700'
    ..style.marginBottom = '12px';

  final videoWrap = html.DivElement()
    ..style.width = 'min(720px, 100%)'
    ..style.maxHeight = '70vh'
    ..style.borderRadius = '18px'
    ..style.overflow = 'hidden'
    ..style.background = '#111111';

  final video = html.VideoElement()
    ..autoplay = true
    ..muted = true
    ..style.width = '100%'
    ..style.height = '100%'
    ..style.objectFit = 'cover';
  video.setAttribute('playsinline', 'true');

  final error = html.DivElement()
    ..style.color = '#fecaca'
    ..style.marginTop = '12px'
    ..style.maxWidth = '720px'
    ..style.textAlign = 'center';

  final actions = html.DivElement()
    ..style.display = 'flex'
    ..style.gap = '12px'
    ..style.flexWrap = 'wrap'
    ..style.justifyContent = 'center'
    ..style.marginTop = '18px';

  html.ButtonElement button(String text) {
    return html.ButtonElement()
      ..text = text
      ..style.border = '0'
      ..style.borderRadius = '999px'
      ..style.padding = '12px 20px'
      ..style.fontWeight = '700'
      ..style.cursor = 'pointer';
  }

  final captureButton = button('Capture Photo')
    ..style.background = '#ffffff'
    ..style.color = '#1f2937';
  final closeButton = button('Close')
    ..style.background = '#374151'
    ..style.color = '#ffffff';

  void finish(Uint8List? bytes) {
    if (completer.isCompleted) {
      return;
    }

    stream?.getTracks().forEach((track) => track.stop());
    overlay.remove();
    completer.complete(bytes);
  }

  closeButton.onClick.listen((_) => finish(null));

  captureButton.onClick.listen((_) {
    try {
      final width = video.videoWidth;
      final height = video.videoHeight;

      if (width <= 0 || height <= 0) {
        error.text = 'Camera is not ready yet. Please try again.';
        return;
      }

      final canvas = html.CanvasElement(width: width, height: height);
      final context = canvas.context2D;
      context.drawImageScaled(video, 0, 0, width, height);

      final dataUrl = canvas.toDataUrl('image/jpeg', 0.88);
      final commaIndex = dataUrl.indexOf(',');

      if (commaIndex < 0) {
        error.text = 'Unable to capture photo.';
        return;
      }

      finish(base64Decode(dataUrl.substring(commaIndex + 1)));
    } catch (_) {
      error.text = 'Unable to capture photo.';
    }
  });

  videoWrap.children.add(video);
  actions.children.addAll([captureButton, closeButton]);
  overlay.children.addAll([title, videoWrap, error, actions]);
  html.document.body?.append(overlay);

  Future<html.MediaStream> openStream(Map<String, dynamic> constraints) {
    return html.window.navigator.mediaDevices!.getUserMedia(constraints);
  }

  try {
    stream = await openStream({
      'audio': false,
      'video': {
        'facingMode': {'ideal': facingMode},
        'width': {'ideal': 1280},
        'height': {'ideal': 720},
      },
    });
  } catch (_) {
    try {
      stream = await openStream({'audio': false, 'video': true});
    } catch (error) {
      overlay.remove();
      final normalizedError = error.toString().toLowerCase();

      if (normalizedError.contains('notfound') ||
          normalizedError.contains('devicesnotfound') ||
          normalizedError.contains('no video input') ||
          normalizedError.contains('requested device not found')) {
        throw StateError('No camera was detected on this browser/device.');
      }

      if (normalizedError.contains('notallowed') ||
          normalizedError.contains('permission') ||
          normalizedError.contains('denied') ||
          normalizedError.contains('security')) {
        throw StateError(
          'Unable to access the camera. Please allow camera permission and use HTTPS or localhost.',
        );
      }

      throw StateError(
        'Unable to access the camera. Please allow camera permission and use HTTPS or localhost.',
      );
    }
  }

  video.srcObject = stream;

  try {
    await video.play();
  } catch (_) {
    // Some browsers start playback automatically after srcObject is assigned.
  }

  return completer.future;
}
