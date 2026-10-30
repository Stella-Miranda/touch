import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:image/image.dart' as img;

import 'services/ai_service.dart';
import 'services/hand_cluster_detector.dart';
import 'services/hand_tracker.dart';

/// Linux desktop has no camera plugin; it shows a placeholder instead.
/// (`dart:io`'s Platform can't be used because it doesn't exist on web.)
final bool _isLinuxDesktop =
    !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

/// The inputs [_nv21ToJpeg] needs, packaged so the conversion can be handed
/// to a background isolate. A [CameraImage] itself isn't worth sending: only
/// its single NV21 plane and dimensions matter.
class _JpegRequest {
  const _JpegRequest({
    required this.bytes,
    required this.width,
    required this.height,
    required this.targetSize,
    required this.quality,
  });

  final Uint8List bytes;
  final int width;
  final int height;
  final int targetSize;
  final int quality;
}

/// Converts an NV21 camera frame straight into a small JPEG, downsampling
/// *while* converting rather than after.
///
/// The previous version converted every pixel of the full-resolution frame
/// into an intermediate RGB image and only then resized it, which meant
/// ~345k pixels of floating-point YUV maths plus a second resize pass — on
/// the UI isolate, so it also froze the preview. Sampling the source frame
/// directly at the output resolution does roughly a tenth of that work, and
/// running it through [compute] keeps the remainder off the UI thread. This
/// is what made "Capturing base image…" and "Analyzing pointed detail…" sit
/// on screen for seconds.
///
/// Top-level (not a method) because isolate entry points must be.
Uint8List _nv21ToJpeg(_JpegRequest request) {
  final bytes = request.bytes;
  final width = request.width;
  final height = request.height;
  final ySize = width * height;
  final chromaWidth = width ~/ 2;

  final longestSide = width > height ? width : height;
  final scale = request.targetSize / longestSide;
  final outWidth = scale < 1 ? (width * scale).round() : width;
  final outHeight = scale < 1 ? (height * scale).round() : height;

  final out = img.Image(width: outWidth, height: outHeight);

  for (int oy = 0; oy < outHeight; oy++) {
    final sy = oy * height ~/ outHeight;
    final yRowStart = sy * width;
    final chromaRowStart = ySize + (sy >> 1) * chromaWidth * 2;

    for (int ox = 0; ox < outWidth; ox++) {
      final sx = ox * width ~/ outWidth;
      final vuIndex = chromaRowStart + (sx >> 1) * 2;
      if (vuIndex + 1 >= bytes.length) continue;

      final yValue = bytes[yRowStart + sx];
      final v = bytes[vuIndex] - 128;
      final u = bytes[vuIndex + 1] - 128;

      final r = (yValue + 1.402 * v).round().clamp(0, 255);
      final g = (yValue - 0.344136 * u - 0.714136 * v).round().clamp(0, 255);
      final b = (yValue + 1.772 * u).round().clamp(0, 255);

      out.setPixelRgb(ox, oy, r, g, b);
    }
  }

  return Uint8List.fromList(img.encodeJpg(out, quality: request.quality));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Direct Pointing Assistant',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

enum AppState { idle, active }

class _MyHomePageState extends State<MyHomePage> {
  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  CameraDescription? _activeCamera;

  late final AIService _aiService;
  final FlutterTts _flutterTts = FlutterTts();
  final HandTracker _handTracker = HandTracker();
  final HandClusterDetector _handClusterDetector = HandClusterDetector();

  bool _isDetectingHand = false;

  AppState _state = AppState.idle;
  String _statusMessage =
      'Point your finger at the painting, then press "Start Session".';

  /// ⚙️ How fast the answer is spoken — the one place to change the voice
  /// speed. Lower is slower, higher is faster.
  ///
  /// flutter_tts doubles this value before handing it to the Android engine,
  /// so 0.5 is the engine's normal speaking speed; 0.45 is a little slower
  /// than normal, and the previous 0.9 was nearly twice normal speed. Useful
  /// range here is roughly 0.3 (very slow) to 0.6 (brisk).
  static const double _speechRate = 0.55;

  /// Per-character allowance in the speech timeout below. It has to stay
  /// comfortably above how long a character actually takes to say at
  /// [_speechRate], so raise it too if the voice is slowed down much further.
  static const int _speechTimeoutMsPerChar = 220;

  /// Set once at startup if the device has no Vietnamese voice installed, so
  /// the warning is shown in one fixed place instead of being appended to the
  /// answer text every time an utterance doesn't report success.
  String? _ttsWarning;

  bool _isProcessingPoint = false;

  /// Serialises speech: every sentence is appended here and spoken only once
  /// the previous one has actually finished. Speaking sentences concurrently
  /// makes each `speak()` flush the one before it, which is why streamed
  /// answers came out as a fragment or as nothing at all.
  Future<void> _speechQueue = Future<void>.value();

  /// Bumped every time a new answer starts speaking, so sentences queued by a
  /// previous, superseded answer skip themselves instead of talking over it.
  int _speechGeneration = 0;

  /// Consecutive analysis failures. The capture loop retries on a timer, so
  /// without this a dead API key turns into an invisible request every few
  /// seconds forever; after this many the session stops and shows why.
  int _consecutiveFailures = 0;
  static const int _maxConsecutiveFailures = 3;

  /// Fallback cadence: if hand movement isn't confidently detected between
  /// captures, describe the currently-pointed detail again anyway so the
  /// user isn't left waiting on a missed detection. Measured from the end of
  /// the previous answer's speech, not from the end of its generation.
  static const Duration _captureFallbackInterval = Duration(seconds: 4);

  Offset? _latestHandPoint;
  CameraImage? _latestFrame;
  double? _lastPointedX;
  double? _lastPointedY;
  DateTime? _lastCaptureTime;

  // ⚠️ PUT YOUR ACTUAL GEMINI API KEY HERE
  final String _apiKey =
      'AQ.Ab8RN6LBeaHVtp_c70NwIN9p-FK-HgJIFyrisokb9SUn6Skg-g';

  @override
  void initState() {
    super.initState();
    _aiService = AIService(
      apiKey: _apiKey,
      // Set false to fail outright when both rotation models are out of
      // quota, instead of waiting on the slow high-limit fallback.
      allowFallback: true,
      onModelSelected: _onModelSelected,
    );
    unawaited(_configureTts());
    _initCamera();
  }

  /// Shows which model is handling this capture, but only when it's one the
  /// user will be left waiting on — otherwise the message would just flicker
  /// past on every fast capture.
  void _onModelSelected(ModelProfile profile) {
    if (!profile.slow || !mounted) return;
    setState(() {
      _statusMessage =
          'Đang dùng mô hình dự phòng (${profile.name}) vì đã hết lượt của '
          'các mô hình nhanh. Có thể mất khoảng 20-45 giây...';
    });
  }

  Future<void> _configureTts() async {
    // Must be set before any speak() call: it's what makes the speak()
    // future resolve only once playback actually finishes, instead of as
    // soon as playback starts.
    await _flutterTts.awaitSpeakCompletion(true);

    // setLanguage returns 1 on success, not-1 (often 0) if the device has no
    // vi-VN voice installed. It never throws, so without this check a
    // missing voice pack shows up as "speak() does nothing" with no error.
    final languageResult = await _flutterTts.setLanguage('vi-VN');
    if (languageResult != 1) {
      print(
        '>>> [TTS WARNING] vi-VN not available on this device '
        '(result=$languageResult).',
      );
      if (mounted) {
        setState(() {
          _ttsWarning =
              'Thiết bị chưa có giọng tiếng Việt. Cài trong Cài đặt > '
              'Text-to-speech > Cài dữ liệu giọng nói > Tiếng Việt.';
        });
      }
    }

    // Diagnostic only: prints what the TTS engine actually reports so a
    // "not available" verdict above can be confirmed against the device's
    // real installed-language list instead of guessed at.
    try {
      final isAvailable = await _flutterTts.isLanguageAvailable('vi-VN');
      print('>>> [TTS] isLanguageAvailable(vi-VN) = $isAvailable');
      print('>>> [TTS] installed languages = ${await _flutterTts.getLanguages}');
    } catch (e) {
      print('>>> [TTS] language diagnostics failed: $e');
    }

    // Android and iOS treat 0.5 as normal speed; browsers treat 1.0 as normal.
    await _flutterTts.setSpeechRate(kIsWeb ? _speechRate * 2 : _speechRate);
    await _flutterTts.setPitch(1.0);
  }

  /// Appends [text] to the speech queue for answer [generation]. Returns
  /// immediately — playback happens in the background, which is what lets an
  /// answer start being spoken while the rest of it is still generating.
  void _enqueueSpeech(String text, int generation) {
    _speechQueue = _speechQueue.then((_) async {
      if (!mounted || generation != _speechGeneration) return;
      try {
        // flutter_tts's speak() future is known to sometimes never resolve on
        // Android (particularly after a stop()), so bound it generously by
        // how long this sentence could plausibly take to say. Hitting the
        // bound is not treated as failure: the audio has almost certainly
        // played and only the completion callback went missing.
        await _flutterTts
            .speak(text)
            .timeout(
              Duration(
                milliseconds: 3000 + text.length * _speechTimeoutMsPerChar,
              ),
            );
      } catch (e) {
        print('>>> [TTS ERROR] speak() failed: $e');
      }
    });
  }

  /// Starts a new answer: silences anything still playing from the previous
  /// one and abandons its queue. The abandoned queue is dropped rather than
  /// awaited because a `speak()` future interrupted by `stop()` may never
  /// resolve, and waiting on it used to wedge speech permanently.
  int _beginSpeech() {
    final generation = ++_speechGeneration;
    _speechQueue = Future<void>.value();
    unawaited(_flutterTts.stop());
    return generation;
  }

  /// Speaks a standalone message and waits until it has actually been said.
  Future<void> _speak(String text) async {
    final generation = _beginSpeech();
    _enqueueSpeech(text, generation);
    await _speechQueue;
  }

  /// Consumes [textStream] as it arrives: updates the status text
  /// progressively and queues each completed sentence for speech as soon as
  /// it's available, so the answer starts being spoken while the model is
  /// still generating the rest of it.
  ///
  /// Returns once the answer has finished *being spoken*, not merely once it
  /// finished downloading. The previous behaviour of returning early let the
  /// next capture start mid-sentence and cut the answer off with its own
  /// `stop()`, which is why model output was rarely heard in full.
  ///
  /// Returns true if the model produced any text at all.
  Future<bool> _speakStream(Stream<String> textStream) async {
    final int myGeneration = _beginSpeech();

    final sentenceBuffer = StringBuffer();
    final fullText = StringBuffer();
    final sentenceEnd = RegExp(r'[^.!?…]+[.!?…]+');

    await for (final chunk in textStream) {
      if (myGeneration != _speechGeneration) return true;

      sentenceBuffer.write(chunk);
      fullText.write(chunk);
      if (mounted) {
        setState(() => _statusMessage = fullText.toString().trim());
      }

      final pending = sentenceBuffer.toString();
      int consumed = 0;
      for (final match in sentenceEnd.allMatches(pending)) {
        final sentence = match.group(0)!.trim();
        if (sentence.isNotEmpty) _enqueueSpeech(sentence, myGeneration);
        consumed = match.end;
      }
      if (consumed > 0) {
        sentenceBuffer
          ..clear()
          ..write(pending.substring(consumed));
      }
    }

    // A final fragment with no terminating punctuation still has to be said.
    final remaining = sentenceBuffer.toString().trim();
    if (remaining.isNotEmpty) _enqueueSpeech(remaining, myGeneration);

    await _speechQueue;
    return fullText.toString().trim().isNotEmpty;
  }

  Future<void> _initCamera() async {
    // If running on Linux desktop, mock the camera initialization
    if (_isLinuxDesktop) {
      debugPrint('Running on Linux: Bypassing native mobile camera stream.');
      if (mounted) {
        setState(() {
          // Set state to ready without waiting for hardware camera
        });
      }
      return;
    }

    try {
      _cameras = await availableCameras();
    } catch (e) {
      debugPrint('Failed to load cameras: $e');
    }

    if (_cameras.isEmpty) return;

    // Browsers list the front (selfie) camera first on many phones.
    _activeCamera = _cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => _cameras.first,
    );
    _cameraController = CameraController(
      _activeCamera!,
      ResolutionPreset.medium,
      enableAudio: false,
      // nv21 gives raw YCbCr frames, which both HandClusterDetector (for
      // live hand tracking) and _nv21ToJpeg (for snapshotting) read directly.
      imageFormatGroup: ImageFormatGroup.nv21,
    );

    try {
      await _cameraController!.initialize();
      if (kIsWeb) {
        // Web's default flash mode is auto, which toggles the torch on every
        // picture — and the web build takes a picture twice a second.
        try {
          await _cameraController!.setFlashMode(FlashMode.off);
        } catch (_) {}
        unawaited(_webFrameLoop());
        if (mounted) setState(() {});
        return;
      }
      // Start streaming once, here, and keep it running for the controller's
      // whole life. Stopping the stream on reset and restarting it on the
      // next session is what left the app unable to analyse anything after a
      // restart: a startImageStream() that fails after a stop only logs, and
      // every later capture then times out waiting for a frame that never
      // arrives.
      await _startImageStream();
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Camera init error: $e');
    }
  }

  /// Snapshots whatever the live stream is currently seeing, as a small JPEG
  /// ready to send to Gemma. The conversion runs on a background isolate so
  /// it neither blocks the camera preview nor delays the upload.
  Future<Uint8List> _captureSnapshotJpeg() async {
    if (kIsWeb) {
      final picture = await _takeWebPicture();
      final longestSide = picture.width > picture.height
          ? picture.width
          : picture.height;
      final resized = longestSide > 512
          ? img.copyResize(
              picture,
              width: picture.width * 512 ~/ longestSide,
              height: picture.height * 512 ~/ longestSide,
            )
          : picture;
      return Uint8List.fromList(img.encodeJpg(resized, quality: 60));
    }
    final frame = await _waitForFrame();
    return compute(
      _nv21ToJpeg,
      _JpegRequest(
        bytes: frame.planes.first.bytes,
        width: frame.width,
        height: frame.height,
        targetSize: 512,
        quality: 60,
      ),
    );
  }

  /// Waits for the next (or current) buffered frame from the live image
  /// stream. If frames aren't arriving, tries once to restart the stream
  /// rather than simply timing out, so a stream that died in the background
  /// (app resumed, camera reclaimed) recovers instead of breaking every
  /// subsequent capture.
  Future<CameraImage> _waitForFrame() async {
    final stopwatch = Stopwatch()..start();
    bool retried = false;

    while (_latestFrame == null) {
      if (!retried && stopwatch.elapsed > const Duration(seconds: 2)) {
        retried = true;
        print('>>> [CAMERA] No frames yet — restarting image stream.');
        await _restartImageStream();
      }
      if (stopwatch.elapsed > const Duration(seconds: 6)) {
        throw TimeoutException('No camera frame received');
      }
      await Future.delayed(const Duration(milliseconds: 30));
    }

    return _latestFrame!;
  }

  /// Web stand-in for the live image stream, which camera_web doesn't
  /// support: takes a still picture every so often and runs hand detection
  /// on it. Runs for the controller's whole life, like the native stream.
  Future<void> _webFrameLoop() async {
    while (mounted && _cameraController != null) {
      try {
        final point = _handClusterDetector.detectRgb(await _takeWebPicture());
        if (point != null) _updateHandCoordinates(point.dx, point.dy);
      } catch (e) {
        print('>>> [HAND DETECT ERROR] $e');
      }
      await Future.delayed(const Duration(milliseconds: 400));
    }
  }

  /// The camera rejects a second takePicture() while one is still running,
  /// so a caller arriving mid-capture shares the picture being taken.
  Future<img.Image>? _webPictureInFlight;

  Future<img.Image> _takeWebPicture() =>
      _webPictureInFlight ??= _takeWebPictureNow().whenComplete(
        () => _webPictureInFlight = null,
      );

  Future<img.Image> _takeWebPictureNow() async {
    final file = await _cameraController!.takePicture();
    final picture = img.decodeJpg(await file.readAsBytes());
    if (picture == null) throw StateError('Could not decode camera picture');
    return picture;
  }

  void _updateHandCoordinates(double x, double y) {
    _latestHandPoint = Offset(x, y);
    _handTracker.updateCoordinates(x, y);
  }

  Future<void> _startImageStream() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }
    if (_cameraController!.value.isStreamingImages) return;

    try {
      await _cameraController!.startImageStream(_onCameraFrame);
    } catch (e) {
      print('>>> [POSE] Failed to start image stream: $e');
    }
  }

  Future<void> _restartImageStream() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }
    if (_cameraController!.value.isStreamingImages) {
      try {
        await _cameraController!.stopImageStream();
      } catch (e) {
        print('>>> [POSE] Failed to stop image stream: $e');
      }
    }
    await _startImageStream();
  }

  /// Called on every frame of the live camera stream. Finds the pointing
  /// hand by clustering frame colors into a small, distinctly-colored
  /// region (the hand) versus the rest (the painting) via
  /// [_handClusterDetector], and feeds its centroid into [_handTracker] so
  /// the dwell/move-away logic in [_startCaptureLoop] can react to it.
  void _onCameraFrame(CameraImage image) {
    _latestFrame = image;

    if (_isDetectingHand) return;
    _isDetectingHand = true;

    try {
      final point = _handClusterDetector.detect(image);
      if (point != null) {
        _updateHandCoordinates(point.dx, point.dy);
      }
    } catch (e) {
      print('>>> [HAND DETECT ERROR] $e');
    } finally {
      _isDetectingHand = false;
    }
  }

  Future<void> _resetSession() async {
    // Supersede any in-flight answer so its remaining sentences stay silent.
    _beginSpeech();
    _handTracker.resetDwellTimer();
    _latestHandPoint = null;
    _lastPointedX = null;
    _lastPointedY = null;
    _lastCaptureTime = null;
    _consecutiveFailures = 0;
    // The image stream deliberately keeps running: see _initCamera.

    if (!mounted) return;

    setState(() {
      _state = AppState.idle;
      _statusMessage = 'Session reset. Press "Start Session" to begin again.';
    });
  }

  /// Starts describing whatever the user is pointing at.
  ///
  /// There is no longer a separate "capture base image" round-trip. It cost a
  /// full capture plus a full model response before the app could say
  /// anything useful, and it bought nothing: each request to the API is
  /// stateless, so the base image and its acknowledgment were discarded and
  /// never formed part of any later answer.
  Future<void> _startSession() async {
    print(">>> BUTTON CLICKED: Attempting startSession");

    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      print(">>> ERROR: Camera controller not ready!");
      return;
    }

    if (kIsWeb) {
      // iOS Safari only allows speech that starts from a tap, and browsers
      // load their voice list lazily — so do both here, on the button press.
      unawaited(_flutterTts.speak(' '));
      unawaited(_flutterTts.setLanguage('vi-VN'));
    }

    _consecutiveFailures = 0;
    _handTracker.resetDwellTimer();
    _lastPointedX = null;
    _lastPointedY = null;

    setState(() {
      _state = AppState.active;
      _statusMessage = 'Analyzing pointed detail...';
    });

    // A new session is usually a new artwork, so start a fresh conversation
    // rather than having the first answer follow on from the last session's.
    // Which painting has already been introduced is deliberately *not* reset:
    // restarting a session in front of the same painting shouldn't replay its
    // introduction.
    _aiService.resetConversation();

    // Make sure frames are flowing (they normally already are, started at
    // camera init), then describe what the user is pointing at right away.
    if (!kIsWeb) await _startImageStream();
    await _captureAndDescribe();

    if (_state == AppState.active) _startCaptureLoop();
  }

  /// Keeps describing whatever is being pointed at. A capture is triggered
  /// either when the hand is seen moving to a new spot and then holding
  /// still there (a real re-point), or — if that movement isn't confidently
  /// detected — after [_captureFallbackInterval] has passed since the last
  /// answer finished, so a missed detection doesn't stall the app.
  Future<void> _startCaptureLoop() async {
    while (mounted && _state == AppState.active) {
      await Future.delayed(const Duration(milliseconds: 300));

      if (!mounted || _state != AppState.active || _isProcessingPoint) {
        continue;
      }

      final trackedPoint = _latestHandPoint;
      bool shouldCapture = false;

      if (trackedPoint != null) {
        if (_lastPointedX == null || _lastPointedY == null) {
          // No baseline yet since the last capture — record the current
          // position as the baseline instead of treating it as movement.
          _lastPointedX = trackedPoint.dx;
          _lastPointedY = trackedPoint.dy;
        } else if (_handTracker.hasMovedAway(
              trackedPoint.dx,
              trackedPoint.dy,
              _lastPointedX!,
              _lastPointedY!,
            ) &&
            _handTracker.hasDweled(trackedPoint.dx, trackedPoint.dy)) {
          shouldCapture = true;
        }
      }

      if (!shouldCapture && _lastCaptureTime != null) {
        final elapsed = DateTime.now().difference(_lastCaptureTime!);
        if (elapsed >= _captureFallbackInterval) {
          shouldCapture = true;
        }
      }

      if (shouldCapture) {
        await _captureAndDescribe();
      }
    }
  }

  /// Captures the current camera frame, sends it to Gemma as a "pointed"
  /// detail, and speaks the description as it streams in.
  Future<void> _captureAndDescribe() async {
    if (_isProcessingPoint) return;

    _isProcessingPoint = true;
    print('>>> [CAPTURE] Sending snapshot...');

    if (mounted) {
      setState(() => _statusMessage = 'Analyzing pointed detail...');
    }

    try {
      final Uint8List compressedBytes = await _captureSnapshotJpeg();
      print('>>> [CAPTURE] Snapshot ready (${compressedBytes.length} bytes)');

      final spoke = await _speakStream(
        _aiService.sendPointedImageStream(compressedBytes),
      );

      if (spoke) {
        _consecutiveFailures = 0;
      } else {
        await _handleFailure('Không nhận được mô tả từ mô hình.');
      }
    } on AIServiceException catch (e) {
      print('>>> [AI ERROR] $e');
      await _handleFailure(
        e.isAuthFailure
            ? 'API key bị từ chối (HTTP ${e.statusCode}). Key có thể đã hết '
                  'hạn.\n\n${e.message}'
            : 'Lỗi máy chủ HTTP ${e.statusCode}.\n\n${e.message}',
      );
    } on TimeoutException catch (e) {
      print('>>> [CAMERA ERROR] $e');
      await _handleFailure('Không lấy được hình từ máy ảnh. Vui lòng thử lại.');
    } catch (e) {
      print('>>> [ERROR] _captureAndDescribe failed: $e');
      await _handleFailure('Lỗi khi phân tích: $e');
    } finally {
      // Reset the movement baseline and dwell timer so the next capture is
      // only triggered by genuinely new movement, and restart the fallback
      // countdown from now — i.e. from the end of the spoken answer.
      _lastPointedX = null;
      _lastPointedY = null;
      _handTracker.resetDwellTimer();
      _lastCaptureTime = DateTime.now();

      _isProcessingPoint = false;
    }
  }

  /// Shows [detail] and, after [_maxConsecutiveFailures] failures in a row,
  /// ends the session instead of quietly retrying a request that clearly
  /// isn't going to start working.
  Future<void> _handleFailure(String detail) async {
    _consecutiveFailures++;

    if (_consecutiveFailures >= _maxConsecutiveFailures) {
      if (mounted) {
        setState(() {
          _state = AppState.idle;
          _statusMessage =
              'Đã dừng sau $_consecutiveFailures lần lỗi liên tiếp.\n\n$detail';
        });
      }
      await _speak('Không thể phân tích. Đã dừng phiên.');
      return;
    }

    if (mounted) setState(() => _statusMessage = detail);
  }

  @override
  void dispose() {
    // Stop the stream before tearing the controller down; disposing a
    // still-streaming controller throws on Android.
    unawaited(() async {
      final controller = _cameraController;
      _cameraController = null;
      if (controller == null) return;
      if (controller.value.isStreamingImages) {
        try {
          await controller.stopImageStream();
        } catch (e) {
          debugPrint('stopImageStream on dispose failed: $e');
        }
      }
      await controller.dispose();
    }());
    unawaited(_flutterTts.stop());
    _aiService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // On Linux desktop or before camera init, show placeholder instead of infinite spinner
    final bool isCameraReady =
        _isLinuxDesktop ||
        (_cameraController != null && _cameraController!.value.isInitialized);

    if (!isCameraReady) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      body: Stack(
        children: [
          // Background feed placeholder on Linux
          Positioned.fill(
            child: _isLinuxDesktop
                ? Container(
                    color: Colors.grey[900],
                    child: const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.videocam_off,
                            size: 64,
                            color: Colors.grey,
                          ),
                          SizedBox(height: 12),
                          Text(
                            'Linux Desktop Preview Active\n(Connect Galaxy A53 for live hardware camera)',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  )
                : CameraPreview(_cameraController!),
          ),

          // Status response overlay card at the top
          Positioned(
            top: 50,
            left: 16,
            right: 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Card(
                  color: Colors.black.withValues(alpha: 0.75),
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    // An introduction is a dozen times longer than a
                    // description, so the card is capped at half the screen
                    // and scrolls instead of growing off the top of it.
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(context).size.height * 0.5,
                      ),
                      child: SingleChildScrollView(
                        reverse: true,
                        child: Text(
                          _statusMessage,
                          style: const TextStyle(
                            fontSize: 16,
                            color: Colors.white,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
                ),

                // Shown only when the device genuinely has no Vietnamese
                // voice, rather than appended to answers whenever an
                // utterance fails to report completion.
                if (_ttsWarning != null)
                  Card(
                    color: Colors.orange.shade900.withValues(alpha: 0.85),
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Text(
                        _ttsWarning!,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.white,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // Start Session Button
          if (_state == AppState.idle)
            Positioned(
              bottom: 40,
              left: 0,
              right: 0,
              child: Center(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 14,
                    ),
                  ),
                  onPressed: _startSession,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text(
                    'Start Session',
                    style: TextStyle(fontSize: 18),
                  ),
                ),
              ),
            ),

          if (_state == AppState.active)
            Positioned(
              bottom: 40,
              left: 16,
              right: 16,
              child: Center(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white70),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 14,
                    ),
                  ),
                  onPressed: _resetSession,
                  icon: const Icon(Icons.cancel),
                  label: const Text('Reset'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
