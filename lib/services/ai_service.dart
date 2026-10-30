import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../data/dong_ho_paintings.dart';

/// Thrown when the endpoint rejects a request. Carries the HTTP status and
/// the server's own message so the UI can show *why* analysis failed
/// (exhausted quota, bad key, wrong model) instead of a generic "couldn't
/// analyse" that leaves the cause invisible.
class AIServiceException implements Exception {
  AIServiceException(this.statusCode, this.message, {this.retryAfter});

  final int statusCode;
  final String message;

  /// How long the server asked us to wait, when it said so (429 responses
  /// carry a RetryInfo detail).
  final Duration? retryAfter;

  /// The request was refused for a reason another model might not share —
  /// quota exhaustion, or the transient 5xx that Gemma's unsupported
  /// streaming endpoint returns — so it's worth trying the next candidate.
  bool get isWorthFailingOver =>
      statusCode == 429 || statusCode == 500 || statusCode == 503;

  /// Quota exhausted for this model.
  bool get isQuotaExhausted => statusCode == 429;

  bool get isAuthFailure => statusCode == 401 || statusCode == 403;

  @override
  String toString() => 'HTTP $statusCode: $message';
}

/// One model plus the settings it needs. Different models need genuinely
/// different handling here, so the differences live in data rather than in
/// `if (model.startsWith(...))` checks scattered through the request code.
class ModelProfile {
  const ModelProfile(
    this.name, {
    required this.streaming,
    required this.maxOutputTokens,
    this.slow = false,
  });

  final String name;

  /// Whether to use `streamGenerateContent` (answer spoken sentence by
  /// sentence as it generates) or `generateContent` (answer delivered in one
  /// piece). Only models that actually list streaming support should set
  /// this: Gemma advertises `generateContent` only, and its streaming
  /// endpoint returned HTTP 500 on two of three measured attempts, while
  /// non-streaming succeeded every time.
  final bool streaming;

  /// Budget for the whole response. On a thinking model this must also cover
  /// the reasoning, which is invisible to the user but spends the budget
  /// first: Gemma 4 produced *no answer at all* at 160-1000 tokens because
  /// reasoning consumed everything, and answered normally at 1500-3000.
  final int maxOutputTokens;

  /// Marks a model the user will notice waiting for, so the UI can say so.
  final bool slow;
}

class AIService {
  /// Tried in rotation, a different one starting each capture, so a session's
  /// requests are split across two separate quota pools instead of draining
  /// one. Both are fast (~1.5-7s to first token) but have tighter free-tier
  /// limits than Gemma.
  static const List<ModelProfile> rotationModels = [
    ModelProfile('gemini-3.5-flash-lite', streaming: true, maxOutputTokens: 300),
    ModelProfile('gemini-3.1-flash-lite', streaming: true, maxOutputTokens: 300),
  ];

  /// Used only once every rotation model is rate-limited. Much higher output
  /// limits, which is the reason to keep it available, but slow (20-45s) and
  /// non-streaming, so the whole answer arrives at once.
  static const ModelProfile fallbackModel = ModelProfile(
    'gemma-4-31b-it',
    streaming: false,
    maxOutputTokens: 3000,
    slow: true,
  );

  /// How many times to work through the whole candidate list before giving
  /// up on a capture. These endpoints return transient 5xx often enough that
  /// a single attempt each is not enough: measured over five consecutive
  /// calls, `gemini-3.5-flash-lite` succeeded 5/5, `gemini-3.1-flash-lite`
  /// 3/5, and `gemma-4-31b-it` only 1/5. A healthy model answers on the
  /// first attempt, so the extra passes cost nothing in the normal case.
  static const int maxPasses = 3;

  /// Brief pause between passes, so a momentary wobble has time to clear
  /// without making a failed capture feel stuck.
  static const Duration retryBackoff = Duration(milliseconds: 400);

  AIService({
    required this.apiKey,
    this.allowFallback = true,
    this.onModelSelected,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String apiKey;

  /// Set false to fail outright when the rotation models are exhausted,
  /// rather than falling back to the slow high-limit model.
  final bool allowFallback;

  /// Called with the profile actually used for a capture, before the wait
  /// begins, so the UI can warn that a slow fallback is in play.
  final void Function(ModelProfile profile)? onModelSelected;

  /// One client for the whole app. Opening a new [http.Client] per capture
  /// paid a fresh DNS lookup, TCP connect and TLS handshake every time —
  /// hundreds of milliseconds of dead time on a mobile connection, on top of
  /// the model's own latency. Injectable so the rotation and failover rules
  /// can be tested without real network calls.
  final http.Client _client;

  /// Where the rotation resumes on the next capture.
  int _rotationIndex = 0;

  /// Models known to be rate-limited, and when they're worth trying again.
  final Map<String, DateTime> _cooldownUntil = {};

  /// Releases the shared connection. Call from the owning widget's dispose().
  void dispose() => _client.close();

  /// What the model answers with when the artwork isn't one of the three it
  /// knows — which is the normal case for any other painting, so this is not
  /// a failure: the answer simply carries on as a plain description.
  static const String unknownArtworkCode = 'KHONG_RO';

  /// The label line every answer has to start with, and what each code means.
  ///
  /// Recognition is folded into the description request rather than asked as
  /// a separate call. A second request per capture would double the traffic
  /// of the whole app against a free-tier quota that is already the binding
  /// constraint, to answer a question the model is looking at the image for
  /// anyway. The cost of doing it this way is the one label line, which
  /// [_readLabel] strips back off before anything is spoken.
  ///
  /// Built from [kDongHoPaintings], so adding a painting means changing only
  /// that list.
  static String get _labelInstruction {
    final options = kDongHoPaintings
        .map((p) => '- ${p.code}: tranh Đông Hồ “${p.title}” (${p.recognitionHint}).')
        .join('\n');
    return 'DÒNG ĐẦU TIÊN của câu trả lời chỉ gồm một mã cho biết tác phẩm '
        'trong ảnh là bức nào:\n$options\n'
        '- $unknownArtworkCode: nếu tác phẩm không phải một trong các bức '
        'trên.\nSau đó xuống dòng, rồi mới mô tả.';
  }

  /// Sent on the first capture of a conversation, when the model has no
  /// earlier answers to build on.
  static final String _openingPrompt =
      'Bạn là một trợ lý nghệ thuật ngắn gọn. Trong ảnh có một ngón tay đang '
      'chỉ vào một chi tiết của tác phẩm.\n\n$_labelInstruction\n\n'
      'Hãy mô tả ngắn gọn chi tiết mà ngón tay chỉ vào, bằng tiếng Việt, '
      'trong khoảng 2 câu. Trả lời trực tiếp bằng văn bản thuần, KHÔNG dùng '
      'markdown, JSON, tiêu đề, hay mô tả việc bạn đang làm.';

  /// Sent on every later capture of the same conversation. The model can see
  /// its own previous answers in [_history], so this asks it to carry on from
  /// them rather than restarting the description from scratch — which is what
  /// makes a run of captures sound like one continuous commentary instead of
  /// a series of unrelated blurbs.
  static final String _followUpPrompt =
      'Người xem vừa chỉ sang một chi tiết khác.\n\n$_labelInstruction\n\n'
      'Hãy mô tả ngắn gọn chi tiết mới đó bằng tiếng Việt, trong khoảng 2 '
      'câu, nói tiếp một cách tự nhiên từ những gì bạn vừa nói và KHÔNG lặp '
      'lại nội dung đã mô tả. Trả lời trực tiếp bằng văn bản thuần, KHÔNG '
      'dùng markdown, JSON, tiêu đề, hay mô tả việc bạn đang làm.';

  /// The painting whose introduction has already been spoken, if any.
  ///
  /// Deliberately outlives both [resetConversation] and the session: a
  /// visitor standing in front of the same painting should hear its story
  /// once, not again every time the app starts a new conversation. It changes
  /// only when the model reports a *different* painting.
  DongHoPainting? _introduced;

  /// The painting currently being described, for the UI.
  DongHoPainting? get introducedPainting => _introduced;

  /// Forgets which painting has been introduced, so the next capture of it
  /// tells its story again. Nothing in the app calls this during normal use;
  /// it exists for tests and for a deliberate "start over".
  void forgetIntroduction() => _introduced = null;

  /// How much of the answer to hold back while looking for the label line.
  ///
  /// The label is meant to be the first thing in the answer, so this only has
  /// to cover a model that dresses it up a little ("Mã: LY_NGU"). Holding
  /// back more than this would delay the start of speech for no reason; a
  /// model that ignored the instruction entirely just has its answer spoken
  /// from here as-is.
  static const int _labelScanLimit = 120;

  /// How many captures share one conversation before it is started over.
  ///
  /// Every earlier turn is re-sent with each new request, so the cost of a
  /// conversation grows with its length; restarting caps that. Only the text
  /// of earlier turns is kept (see [_remember]) — at roughly 2 sentences per
  /// answer this is on the order of a hundred tokens per remembered turn,
  /// which is small next to the ~260+ tokens an image alone costs.
  ///
  /// Raise it for longer-running continuity, lower it to spend fewer tokens.
  static const int maxTurnsPerConversation = 6;

  /// The current conversation: alternating user/model turns, oldest first,
  /// in the `contents` shape the endpoint expects. Cleared once a
  /// conversation reaches [maxTurnsPerConversation] turns.
  final List<Map<String, dynamic>> _history = [];

  /// Drops the conversation so the next capture starts a fresh one. Called
  /// when a session begins, since a new session is usually a new artwork and
  /// continuity with the previous one would be misleading.
  void resetConversation() => _history.clear();

  /// Records a completed exchange so the next capture can build on it.
  ///
  /// The image is deliberately *not* kept: re-sending every earlier photo
  /// would dominate the token cost of each request, while the answer text
  /// alone is what the model needs in order to not repeat itself.
  void _remember(String prompt, String answer) {
    final trimmed = answer.trim();
    if (trimmed.isEmpty) return;

    _history.add({
      'role': 'user',
      'parts': [
        {'text': prompt},
      ],
    });
    _history.add({
      'role': 'model',
      'parts': [
        {'text': trimmed},
      ],
    });

    if (_history.length >= maxTurnsPerConversation * 2) {
      print('>>> [AIService] conversation full — starting a new one');
      _history.clear();
    }
  }

  /// The models to try for one capture, in order: the rotation models that
  /// aren't currently rate-limited starting from wherever the rotation left
  /// off, then the fallback. Rate-limited models are still included at the
  /// very end — a cooldown is an estimate, and trying a probably-exhausted
  /// model beats giving up.
  List<ModelProfile> _candidates() {
    final now = DateTime.now();
    final start = _rotationIndex % rotationModels.length;
    _rotationIndex = (start + 1) % rotationModels.length;

    final ready = <ModelProfile>[];
    final cooling = <ModelProfile>[];
    for (int i = 0; i < rotationModels.length; i++) {
      final profile = rotationModels[(start + i) % rotationModels.length];
      final until = _cooldownUntil[profile.name];
      if (until != null && until.isAfter(now)) {
        cooling.add(profile);
      } else {
        ready.add(profile);
      }
    }
    // `now` is captured once so every model in this capture is judged
    // against the same instant.

    return [
      ...ready,
      if (allowFallback) fallbackModel,
      ...cooling,
    ];
  }

  /// Streams what should be said about whatever detail is being pointed at.
  ///
  /// Usually that is just the description, exactly as before. When the model
  /// reports that the artwork is one of [kDongHoPaintings] and it isn't the
  /// one already introduced, that painting's introduction is spoken first and
  /// the description follows it — so a visitor who walks up to a known
  /// painting hears its story once, and anything else is simply described.
  ///
  /// Tries each candidate model in turn, moving on when one is out of quota
  /// or returns a transient server error, and works through the list up to
  /// [maxPasses] times before giving up. Failover happens strictly before
  /// any text is emitted, so a switch can never splice two models' answers
  /// together.
  Stream<String> sendPointedImageStream(Uint8List imageBytes) async* {
    final base64Image = base64Encode(imageBytes);
    final candidates = _candidates();
    final prompt = _history.isEmpty ? _openingPrompt : _followUpPrompt;
    AIServiceException? lastError;

    for (int pass = 0; pass < maxPasses; pass++) {
      if (pass > 0) await Future<void>.delayed(retryBackoff);

      for (final profile in candidates) {
        // A model that answered 429 earlier in this same capture won't have
        // recovered seconds later, so don't spend another request on it.
        if (pass > 0 && _isCoolingDown(profile.name)) continue;

        try {
          // Announced before the request, not after: on the slow fallback
          // the user is about to wait a minute and should be told why while
          // it happens, not once it's over.
          onModelSelected?.call(profile);
          final text = await _open(profile, base64Image, prompt);
          // Only the model's own description is buffered here, so that is all
          // that joins the conversation: an introduction is fixed text the
          // app added, and remembering it as something the model "said" would
          // have it treated as commentary already given. Only a turn that
          // actually completed is remembered — a half-spoken answer cut off
          // by an error would poison every later request.
          final description = StringBuffer();
          await for (final chunk in _spoken(text, description)) {
            yield chunk;
          }
          _remember(prompt, description.toString());
          return;
        } on AIServiceException catch (e) {
          print('>>> [AIService] ${profile.name} failed (pass $pass): $e');
          if (e.isQuotaExhausted) {
            final until = DateTime.now().add(
              e.retryAfter ?? const Duration(minutes: 1),
            );
            _cooldownUntil[profile.name] = until;
            print('>>> [AIService] ${profile.name} on cooldown until $until');
          }
          // An invalid key or a malformed request fails identically on every
          // model, so there is nothing to fail over to.
          if (!e.isWorthFailingOver) rethrow;
          lastError = e;
        }
      }
    }

    throw lastError ??
        AIServiceException(0, 'Không có mô hình nào khả dụng.');
  }

  /// Turns the raw answer into what should actually be spoken: the label line
  /// removed, a painting's introduction inserted ahead of the description the
  /// first time that painting is seen.
  ///
  /// The model's own words are appended to [description] as they pass through,
  /// so the caller can remember the description without the introduction.
  ///
  /// Only the start of the answer is held back, and only until the label can
  /// be read (see [_labelScanLimit]), so a description still begins being
  /// spoken while the rest of it is generating.
  Stream<String> _spoken(
    Stream<String> answer,
    StringBuffer description,
  ) async* {
    final head = StringBuffer();
    bool labelRead = false;

    await for (final chunk in answer) {
      if (labelRead) {
        description.write(chunk);
        yield chunk;
        continue;
      }

      head.write(chunk);
      final text = head.toString();
      // Wait for the end of the first line — or for enough text to be sure
      // there isn't going to be one.
      if (!text.contains('\n') && text.length < _labelScanLimit) continue;

      labelRead = true;
      yield* _openAnswer(text, description);
    }

    // A short answer can end before either condition is met.
    if (!labelRead) yield* _openAnswer(head.toString(), description);
  }

  /// Emits the beginning of an answer: the introduction, if this is a painting
  /// we haven't introduced yet, then whatever is left once the label has been
  /// taken off the front.
  Stream<String> _openAnswer(String text, StringBuffer description) async* {
    final label = _readLabel(text);
    final body = label == null ? text : _stripLabel(text, label);
    final painting = label == null
        ? null
        : kDongHoPaintings.where((p) => p.code == label).firstOrNull;

    // An unrecognised artwork leaves [_introduced] alone rather than clearing
    // it: recognition can wobble between captures of the same painting, and
    // clearing here would make its introduction play a second time as soon as
    // it was recognised again.
    if (painting != null && painting.code != _introduced?.code) {
      print('>>> [AIService] introducing ${painting.title}');
      _introduced = painting;
      // A different painting makes everything said so far irrelevant, and
      // "carry on from what you just said" would be actively wrong.
      _history.clear();
      yield '${painting.introduction}\n\n';
    }

    if (body.isNotEmpty) {
      description.write(body);
      yield body;
    }
  }

  /// Finds the label the answer was asked to open with, or null if the model
  /// didn't use one. The codes share no common substring and don't occur in
  /// ordinary Vietnamese prose, so a substring test is enough and tolerates
  /// the model wrapping the code in punctuation or a word or two.
  static String? _readLabel(String text) {
    final upper = text.toUpperCase();
    for (final code in [
      for (final painting in kDongHoPaintings) painting.code,
      unknownArtworkCode,
    ]) {
      if (upper.contains(code)) return code;
    }
    return null;
  }

  /// Removes the label from the front of an answer: the whole first line when
  /// the label sits on its own line as asked, otherwise just the code itself.
  static String _stripLabel(String text, String label) {
    final at = text.toUpperCase().indexOf(label);
    final newline = text.indexOf('\n', at);
    final rest = newline >= 0
        ? text.substring(newline + 1)
        : text.substring(at + label.length);
    // Leading spaces, colons and dashes left over from "Mã: LY_NGU -".
    return rest.replaceFirst(RegExp(r'^[\s:\-–—.,]+'), '');
  }

  bool _isCoolingDown(String model) {
    final until = _cooldownUntil[model];
    return until != null && until.isAfter(DateTime.now());
  }

  /// Sends the request and checks the response status *before* returning a
  /// text stream, so the caller can still fail over to another model.
  Future<Stream<String>> _open(
    ModelProfile profile,
    String base64Image,
    String prompt,
  ) async {
    // No 'systemInstruction' key: Gemma rejects it outright with HTTP 500
    // "Internal error encountered." (reproducible — the identical request
    // without it succeeds), which made every analysis fail. The instruction
    // is folded into the prompt text instead, which every model accepts.
    final body = jsonEncode({
      'contents': [
        // Earlier turns of this conversation first, so the model answers in
        // the context of what it has already said.
        ..._history,
        {
          'role': 'user',
          'parts': [
            {
              'inline_data': {'mime_type': 'image/jpeg', 'data': base64Image},
            },
            {'text': prompt},
          ],
        },
      ],
      'generationConfig': {
        'temperature': 0.5,
        'maxOutputTokens': profile.maxOutputTokens,
      },
    });

    final method = profile.streaming
        ? 'streamGenerateContent?alt=sse&'
        : 'generateContent?';
    final url =
        'https://generativelanguage.googleapis.com/v1beta/models/'
        '${profile.name}:$method' 'key=$apiKey';

    final request = http.Request('POST', Uri.parse(url))
      ..headers['Content-Type'] = 'application/json'
      ..body = body;

    // A slow thinking model can sit silent for well over a minute before its
    // first token, so the timeout has to allow for that.
    final response = await _client
        .send(request)
        .timeout(Duration(seconds: profile.slow ? 120 : 30));

    print('>>> [AIService] ${profile.name} status: ${response.statusCode}');

    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      print('>>> [AIService ERROR] body: $body');
      throw AIServiceException(
        response.statusCode,
        _extractErrorMessage(body),
        retryAfter: _extractRetryDelay(body),
      );
    }

    return profile.streaming
        ? _readSse(response.stream)
        : _readWhole(response.stream);
  }

  /// Reads server-sent events, yielding answer text as it arrives. Plain text
  /// rather than a JSON-wrapped format is required: JSON can't be usefully
  /// parsed until its closing brace arrives, which would defeat the point of
  /// streaming for early speech.
  Stream<String> _readSse(Stream<List<int>> body) async* {
    final lines = body.transform(utf8.decoder).transform(const LineSplitter());

    await for (final line in lines) {
      if (!line.startsWith('data: ')) continue;
      final jsonStr = line.substring(6).trim();
      if (jsonStr.isEmpty) continue;

      try {
        final Map<String, dynamic> data = jsonDecode(jsonStr);
        for (final text in _answerParts(data)) {
          yield text;
        }
      } catch (e) {
        print('>>> [AIService ERROR] Failed to parse SSE chunk: $e');
      }
    }
  }

  /// Reads a complete non-streaming response and yields its answer in one
  /// piece.
  Stream<String> _readWhole(Stream<List<int>> body) async* {
    final raw = await body.transform(utf8.decoder).join();
    final Map<String, dynamic> data = jsonDecode(raw);
    final text = _answerParts(data).join();
    if (text.isNotEmpty) yield text;
  }

  /// Pulls the real answer out of a response, dropping the model's internal
  /// reasoning. Thinking models emit those as parts marked `thought: true`
  /// ahead of the answer; speaking them aloud would be gibberish.
  Iterable<String> _answerParts(Map<String, dynamic> data) sync* {
    final List<dynamic> parts =
        data['candidates']?[0]?['content']?['parts'] ?? const [];
    for (final part in parts) {
      if (part is! Map) continue;
      if (part['thought'] == true) continue;
      final text = part['text']?.toString() ?? '';
      if (text.isNotEmpty) yield text;
    }
  }

  /// Pulls the human-readable reason out of the API's JSON error envelope,
  /// falling back to the raw body when it isn't shaped as expected.
  String _extractErrorMessage(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map && error['message'] != null) {
          return error['message'].toString();
        }
      }
    } catch (_) {
      // Not JSON — fall through to the raw body.
    }
    final trimmed = body.trim();
    return trimmed.isEmpty
        ? 'Không có phản hồi từ máy chủ.'
        : (trimmed.length > 300 ? '${trimmed.substring(0, 300)}…' : trimmed);
  }

  /// Reads the RetryInfo detail a 429 carries (`"retryDelay": "37s"`), so a
  /// rate-limited model is retried when the server said to rather than after
  /// an arbitrary guess.
  Duration? _extractRetryDelay(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final details = decoded['error']?['details'];
      if (details is! List) return null;
      for (final detail in details) {
        if (detail is! Map) continue;
        final delay = detail['retryDelay']?.toString();
        if (delay == null) continue;
        final seconds = double.tryParse(delay.replaceAll('s', '').trim());
        if (seconds != null) {
          return Duration(milliseconds: (seconds * 1000).round());
        }
      }
    } catch (_) {
      // Malformed details — fall back to the caller's default.
    }
    return null;
  }
}
