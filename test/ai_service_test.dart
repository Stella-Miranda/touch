import 'dart:convert';
import 'dart:typed_data';

import 'package:direct_pointing_assistant/data/dong_ho_paintings.dart';
import 'package:direct_pointing_assistant/services/ai_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// An SSE body shaped like the real streaming endpoint's.
String _sse(List<String> chunks) => chunks
    .map((text) => 'data: ${jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': text},
                ],
              },
            },
          ],
        })}\n\n')
    .join();

/// An SSE response with the charset spelled out: http.Response falls back to
/// latin1 without it, which mangles the accented characters the real endpoint
/// sends as UTF-8.
http.Response _sseResponse(List<String> chunks) => http.Response(
      _sse(chunks),
      200,
      headers: {'content-type': 'text/event-stream; charset=utf-8'},
    );

String _wholeBody(String text) => jsonEncode({
      'candidates': [
        {
          'content': {
            'parts': [
              {'text': text},
            ],
          },
        },
      ],
    });

String _quotaBody({String? retryDelay}) => jsonEncode({
      'error': {
        'code': 429,
        'message': 'Quota exceeded.',
        'status': 'RESOURCE_EXHAUSTED',
        if (retryDelay != null)
          'details': [
            {
              '@type': 'type.googleapis.com/google.rpc.RetryInfo',
              'retryDelay': retryDelay,
            },
          ],
      },
    });

/// Pulls the model id out of the request URL the service built.
String _modelOf(http.BaseRequest request) {
  final path = request.url.pathSegments.last;
  return path.split(':').first;
}

/// The `contents` array of a request body, as the service built it.
List<dynamic> _contentsOf(http.BaseRequest request) {
  final decoded = jsonDecode((request as http.Request).body);
  return (decoded as Map)['contents'] as List<dynamic>;
}

/// Every text part of a request, in order — the earlier turns the service
/// replayed plus the prompt it asked this time.
List<String> _textsOf(http.BaseRequest request) => [
      for (final turn in _contentsOf(request))
        for (final part in (turn as Map)['parts'] as List<dynamic>)
          if ((part as Map)['text'] != null) part['text'] as String,
    ];

final Uint8List _image = Uint8List.fromList([1, 2, 3, 4]);

void main() {
  group('AIService model rotation', () {
    test('alternates between the rotation models on successive captures',
        () async {
      final used = <String>[];
      final service = AIService(
        apiKey: 'k',
        client: MockClient((request) async {
          used.add(_modelOf(request));
          return http.Response(_sse(['ok.']), 200);
        }),
      );

      for (var i = 0; i < 4; i++) {
        await service.sendPointedImageStream(_image).join();
      }

      expect(used, [
        'gemini-3.5-flash-lite',
        'gemini-3.1-flash-lite',
        'gemini-3.5-flash-lite',
        'gemini-3.1-flash-lite',
      ]);
    });

    test('never calls the fallback while a rotation model still answers',
        () async {
      final used = <String>[];
      final service = AIService(
        apiKey: 'k',
        client: MockClient((request) async {
          used.add(_modelOf(request));
          return http.Response(_sse(['ok.']), 200);
        }),
      );

      await service.sendPointedImageStream(_image).join();

      expect(used, ['gemini-3.5-flash-lite']);
      expect(used, isNot(contains('gemma-4-31b-it')));
    });
  });

  group('AIService failover', () {
    test('moves to the other rotation model when the first is out of quota',
        () async {
      final used = <String>[];
      final service = AIService(
        apiKey: 'k',
        client: MockClient((request) async {
          final model = _modelOf(request);
          used.add(model);
          if (model == 'gemini-3.5-flash-lite') {
            return http.Response(_quotaBody(), 429);
          }
          return http.Response(_sse(['second model.']), 200);
        }),
      );

      final text = await service.sendPointedImageStream(_image).join();

      expect(used, ['gemini-3.5-flash-lite', 'gemini-3.1-flash-lite']);
      expect(text, 'second model.');
    });

    test('falls back to Gemma only once both rotation models are exhausted',
        () async {
      final used = <String>[];
      final service = AIService(
        apiKey: 'k',
        client: MockClient((request) async {
          final model = _modelOf(request);
          used.add(model);
          if (model.startsWith('gemini-')) {
            return http.Response(_quotaBody(), 429);
          }
          return http.Response(_wholeBody('gemma answer.'), 200);
        }),
      );

      final text = await service.sendPointedImageStream(_image).join();

      expect(used, [
        'gemini-3.5-flash-lite',
        'gemini-3.1-flash-lite',
        'gemma-4-31b-it',
      ]);
      expect(text, 'gemma answer.');
    });

    test('uses the non-streaming endpoint for the fallback and SSE for the '
        'rotation models', () async {
      final methods = <String, String>{};
      final service = AIService(
        apiKey: 'k',
        client: MockClient((request) async {
          final model = _modelOf(request);
          methods[model] = request.url.pathSegments.last.split(':').last;
          if (model.startsWith('gemini-')) {
            return http.Response(_quotaBody(), 429);
          }
          return http.Response(_wholeBody('x.'), 200);
        }),
      );

      await service.sendPointedImageStream(_image).join();

      expect(methods['gemini-3.5-flash-lite'], 'streamGenerateContent');
      expect(methods['gemma-4-31b-it'], 'generateContent');
    });

    test('skips the fallback entirely when allowFallback is false', () async {
      final used = <String>[];
      final service = AIService(
        apiKey: 'k',
        allowFallback: false,
        client: MockClient((request) async {
          used.add(_modelOf(request));
          return http.Response(_quotaBody(), 429);
        }),
      );

      await expectLater(
        service.sendPointedImageStream(_image).join(),
        throwsA(isA<AIServiceException>()
            .having((e) => e.statusCode, 'statusCode', 429)),
      );
      expect(used, isNot(contains('gemma-4-31b-it')));
    });

    test('fails over past the transient 500 Gemma streaming returns',
        () async {
      var calls = 0;
      final service = AIService(
        apiKey: 'k',
        client: MockClient((request) async {
          calls++;
          if (calls == 1) {
            return http.Response('{"error":{"message":"Internal"}}', 500);
          }
          return http.Response(_sse(['recovered.']), 200);
        }),
      );

      expect(await service.sendPointedImageStream(_image).join(), 'recovered.');
      expect(calls, 2);
    });

    test('does not fail over on an auth error, which no other model fixes',
        () async {
      var calls = 0;
      final service = AIService(
        apiKey: 'bad',
        client: MockClient((request) async {
          calls++;
          return http.Response('{"error":{"message":"bad key"}}', 403);
        }),
      );

      await expectLater(
        service.sendPointedImageStream(_image).join(),
        throwsA(isA<AIServiceException>()
            .having((e) => e.isAuthFailure, 'isAuthFailure', isTrue)),
      );
      expect(calls, 1, reason: 'an invalid key fails on every model alike');
    });
  });

  group('AIService quota cooldown', () {
    // Each capture advances the rotation, so the capture after a failure
    // starts at the *other* model regardless of cooldowns. These tests look
    // at the capture after that, which is the one the rotation brings back
    // around to the model that was rate-limited.
    test('returns to the model once its cooldown has expired', () async {
      final used = <String>[];
      var firstIsExhausted = true;
      final service = AIService(
        apiKey: 'k',
        client: MockClient((request) async {
          final model = _modelOf(request);
          used.add(model);
          if (model == 'gemini-3.5-flash-lite' && firstIsExhausted) {
            // A delay of 0s has already elapsed by the next capture.
            return http.Response(_quotaBody(retryDelay: '0s'), 429);
          }
          return http.Response(_sse(['ok.']), 200);
        }),
      );

      await service.sendPointedImageStream(_image).join();
      expect(used, ['gemini-3.5-flash-lite', 'gemini-3.1-flash-lite']);

      firstIsExhausted = false;
      await service.sendPointedImageStream(_image).join(); // starts at 3.1
      used.clear();
      await service.sendPointedImageStream(_image).join(); // back to 3.5

      expect(used, ['gemini-3.5-flash-lite'],
          reason: 'an expired cooldown must not exclude the model forever');
    });

    test('keeps a rate-limited model out until its cooldown expires',
        () async {
      final used = <String>[];
      final service = AIService(
        apiKey: 'k',
        client: MockClient((request) async {
          final model = _modelOf(request);
          used.add(model);
          if (model == 'gemini-3.5-flash-lite') {
            return http.Response(_quotaBody(retryDelay: '600s'), 429);
          }
          return http.Response(_sse(['ok.']), 200);
        }),
      );

      await service.sendPointedImageStream(_image).join();
      await service.sendPointedImageStream(_image).join(); // starts at 3.1
      used.clear();

      // The rotation comes back around to the exhausted model here; the
      // cooldown must send it straight to the other one instead.
      await service.sendPointedImageStream(_image).join();
      expect(used, ['gemini-3.1-flash-lite'],
          reason: 'the rate-limited model is still on a 600s cooldown');
    });

    test('still tries an exhausted model as a last resort rather than giving '
        'up, since a cooldown is only an estimate', () async {
      final used = <String>[];
      // Counted separately from `used`, which is cleared partway through.
      var totalCalls = 0;
      final service = AIService(
        apiKey: 'k',
        allowFallback: false,
        client: MockClient((request) async {
          used.add(_modelOf(request));
          totalCalls++;
          if (totalCalls <= 2) {
            return http.Response(_quotaBody(retryDelay: '600s'), 429);
          }
          return http.Response(_sse(['recovered early.']), 200);
        }),
      );

      // First capture puts both rotation models on a long cooldown.
      await expectLater(
        service.sendPointedImageStream(_image).join(),
        throwsA(isA<AIServiceException>()),
      );
      used.clear();

      // Both are still nominally cooling down, but quota may have reset
      // sooner than the server predicted, so they are retried anyway.
      expect(await service.sendPointedImageStream(_image).join(),
          'recovered early.');
      expect(used, isNotEmpty);
    });
  });

  group('AIService retry passes', () {
    test('works through the candidates repeatedly until one answers',
        () async {
      var calls = 0;
      final service = AIService(
        apiKey: 'k',
        client: MockClient((request) async {
          calls++;
          // Every candidate is briefly unavailable; the sixth attempt lands.
          if (calls <= 5) {
            return http.Response('{"error":{"message":"overloaded"}}', 503);
          }
          // That sixth attempt falls on the non-streaming fallback, so the
          // body has to match the endpoint the service actually called.
          final streaming = _modelOf(request).startsWith('gemini-');
          return http.Response(
            streaming ? _sse(['finally.']) : _wholeBody('finally.'),
            200,
          );
        }),
      );

      expect(await service.sendPointedImageStream(_image).join(), 'finally.');
      expect(calls, 6);
    });

    test('gives up after maxPasses instead of retrying forever', () async {
      var calls = 0;
      final service = AIService(
        apiKey: 'k',
        client: MockClient((_) async {
          calls++;
          return http.Response('{"error":{"message":"overloaded"}}', 503);
        }),
      );

      await expectLater(
        service.sendPointedImageStream(_image).join(),
        throwsA(isA<AIServiceException>()
            .having((e) => e.statusCode, 'statusCode', 503)),
      );
      // 3 candidates x maxPasses, and no more.
      expect(calls, 3 * AIService.maxPasses);
    });

    test('does not spend later passes on a model that reported no quota',
        () async {
      final used = <String>[];
      final service = AIService(
        apiKey: 'k',
        client: MockClient((request) async {
          final model = _modelOf(request);
          used.add(model);
          if (model == 'gemini-3.5-flash-lite') {
            return http.Response(_quotaBody(retryDelay: '600s'), 429);
          }
          return http.Response('{"error":{"message":"overloaded"}}', 503);
        }),
      );

      await expectLater(
        service.sendPointedImageStream(_image).join(),
        throwsA(isA<AIServiceException>()),
      );

      expect(used.where((m) => m == 'gemini-3.5-flash-lite').length, 1,
          reason: 'quota will not have reset within one capture');
      expect(used.where((m) => m == 'gemma-4-31b-it').length,
          AIService.maxPasses,
          reason: 'a transient 5xx is worth retrying, unlike a 429');
    });

    test('an auth failure stops immediately without burning every pass',
        () async {
      var calls = 0;
      final service = AIService(
        apiKey: 'bad',
        client: MockClient((_) async {
          calls++;
          return http.Response('{"error":{"message":"bad key"}}', 403);
        }),
      );

      await expectLater(
        service.sendPointedImageStream(_image).join(),
        throwsA(isA<AIServiceException>()),
      );
      expect(calls, 1);
    });
  });

  group('AIService response parsing', () {
    test('drops reasoning parts so they are never spoken aloud', () async {
      final body = 'data: ${jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'internal reasoning', 'thought': true},
                    {'text': 'Real answer.'},
                  ],
                },
              },
            ],
          })}\n\n';

      final service = AIService(
        apiKey: 'k',
        client: MockClient((_) async => http.Response(body, 200)),
      );

      expect(await service.sendPointedImageStream(_image).join(), 'Real answer.');
    });

    test('surfaces the server message instead of a generic apology', () async {
      final service = AIService(
        apiKey: 'k',
        allowFallback: false,
        client: MockClient((_) async => http.Response(
            jsonEncode({
              'error': {'code': 400, 'message': 'Developer instruction is not enabled'}
            }),
            400)),
      );

      await expectLater(
        service.sendPointedImageStream(_image).join(),
        throwsA(isA<AIServiceException>().having(
            (e) => e.message, 'message', contains('Developer instruction'))),
      );
    });
  });

  group('AIService conversation', () {
    test('replays earlier answers so a run of captures stays continuous',
        () async {
      final requests = <http.BaseRequest>[];
      final service = AIService(
        apiKey: 'k',
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(_sse(['Answer ${requests.length}.']), 200);
        }),
      );

      await service.sendPointedImageStream(_image).join();
      await service.sendPointedImageStream(_image).join();

      // The first capture has nothing to build on.
      expect(_contentsOf(requests[0]), hasLength(1));

      // The second carries the first exchange ahead of its own prompt.
      expect(_contentsOf(requests[1]), hasLength(3));
      expect(_textsOf(requests[1]), contains('Answer 1.'));
      expect(
        (_contentsOf(requests[1])[1] as Map)['role'],
        'model',
      );
    });

    test('keeps only one image per request, never the earlier ones', () async {
      final requests = <http.BaseRequest>[];
      final service = AIService(
        apiKey: 'k',
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(_sse(['Answer.']), 200);
        }),
      );

      await service.sendPointedImageStream(_image).join();
      await service.sendPointedImageStream(_image).join();
      await service.sendPointedImageStream(_image).join();

      for (final request in requests) {
        final images = [
          for (final turn in _contentsOf(request))
            for (final part in (turn as Map)['parts'] as List<dynamic>)
              if ((part as Map)['inline_data'] != null) part,
        ];
        expect(images, hasLength(1));
      }
    });

    test('starts a new conversation once the turn limit is reached', () async {
      final requests = <http.BaseRequest>[];
      final service = AIService(
        apiKey: 'k',
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(_sse(['Answer.']), 200);
        }),
      );

      for (var i = 0; i < AIService.maxTurnsPerConversation + 1; i++) {
        await service.sendPointedImageStream(_image).join();
      }

      // The capture right after the limit starts over with no history.
      expect(
        _contentsOf(requests[AIService.maxTurnsPerConversation]),
        hasLength(1),
      );
    });

    test('an empty answer is not remembered as a turn', () async {
      final requests = <http.BaseRequest>[];
      final service = AIService(
        apiKey: 'k',
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(_sse(['']), 200);
        }),
      );

      await service.sendPointedImageStream(_image).join();
      await service.sendPointedImageStream(_image).join();

      expect(_contentsOf(requests[1]), hasLength(1));
    });

    test('resetConversation drops the history', () async {
      final requests = <http.BaseRequest>[];
      final service = AIService(
        apiKey: 'k',
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(_sse(['Answer.']), 200);
        }),
      );

      await service.sendPointedImageStream(_image).join();
      service.resetConversation();
      await service.sendPointedImageStream(_image).join();

      expect(_contentsOf(requests[1]), hasLength(1));
    });
  });

  group('AIService painting introductions', () {
    test('speaks the introduction before the first description of a painting',
        () async {
      final service = AIService(
        apiKey: 'k',
        client: MockClient(
          (request) async =>
              _sseResponse(['GA_DA_XUONG\n', 'Ngón tay chỉ vào chiếc mào.']),
        ),
      );

      final spoken = await service.sendPointedImageStream(_image).join();

      final painting =
          kDongHoPaintings.firstWhere((p) => p.code == 'GA_DA_XUONG');
      expect(spoken, startsWith(painting.introduction));
      expect(spoken, endsWith('Ngón tay chỉ vào chiếc mào.'));
      // The label is an instruction to the app, not something to say aloud.
      expect(spoken, isNot(contains('GA_DA_XUONG')));
      expect(service.introducedPainting?.code, 'GA_DA_XUONG');
    });

    test('does not repeat the introduction on later captures of the same '
        'painting', () async {
      final service = AIService(
        apiKey: 'k',
        client: MockClient(
          (request) async => _sseResponse(['LY_NGU\n', 'Chi tiết tiếp theo.']),
        ),
      );

      await service.sendPointedImageStream(_image).join();
      final second = await service.sendPointedImageStream(_image).join();

      expect(second, 'Chi tiết tiếp theo.');
    });

    test('introduces the new painting when the visitor moves to another one',
        () async {
      var code = 'LY_NGU';
      final service = AIService(
        apiKey: 'k',
        client: MockClient(
          (request) async => _sseResponse(['$code\n', 'Chi tiết.']),
        ),
      );

      await service.sendPointedImageStream(_image).join();
      code = 'CHAN_TRAU';
      final second = await service.sendPointedImageStream(_image).join();

      final painting =
          kDongHoPaintings.firstWhere((p) => p.code == 'CHAN_TRAU');
      expect(second, startsWith(painting.introduction));
      expect(service.introducedPainting?.code, 'CHAN_TRAU');
    });

    test('a painting change starts the conversation over', () async {
      var code = 'LY_NGU';
      final requests = <http.BaseRequest>[];
      final service = AIService(
        apiKey: 'k',
        client: MockClient((request) async {
          requests.add(request);
          return _sseResponse(['$code\n', 'Chi tiết.']);
        }),
      );

      await service.sendPointedImageStream(_image).join();
      await service.sendPointedImageStream(_image).join();
      code = 'CHAN_TRAU';
      await service.sendPointedImageStream(_image).join();
      await service.sendPointedImageStream(_image).join();

      // The capture after the change replays nothing: continuing from
      // descriptions of a different painting would be actively wrong.
      expect(_contentsOf(requests[3]), hasLength(3));
    });

    test('an unrecognised artwork is described with no introduction',
        () async {
      final service = AIService(
        apiKey: 'k',
        client: MockClient(
          (request) async =>
              _sseResponse(['KHONG_RO\n', 'Một bông hoa màu đỏ.']),
        ),
      );

      final spoken = await service.sendPointedImageStream(_image).join();

      expect(spoken, 'Một bông hoa màu đỏ.');
      expect(service.introducedPainting, isNull);
    });

    test('an unrecognised capture does not cancel the introduction already '
        'given', () async {
      var code = 'LY_NGU';
      final service = AIService(
        apiKey: 'k',
        client: MockClient(
          (request) async => _sseResponse(['$code\n', 'Chi tiết.']),
        ),
      );

      await service.sendPointedImageStream(_image).join();
      // Recognition wobbles for one capture — a hand covering the painting,
      // a bad angle — and then comes back.
      code = 'KHONG_RO';
      await service.sendPointedImageStream(_image).join();
      code = 'LY_NGU';
      final third = await service.sendPointedImageStream(_image).join();

      expect(third, 'Chi tiết.');
    });

    test('an answer with no label at all is spoken as it is', () async {
      final service = AIService(
        apiKey: 'k',
        client: MockClient(
          (request) async => _sseResponse(['Ngón tay chỉ vào một con cá.']),
        ),
      );

      expect(
        await service.sendPointedImageStream(_image).join(),
        'Ngón tay chỉ vào một con cá.',
      );
    });

    test('a label the model dressed up is still read and removed', () async {
      final service = AIService(
        apiKey: 'k',
        client: MockClient(
          (request) async => _sseResponse(['Mã: CHAN_TRAU. Cậu bé thổi sáo.']),
        ),
      );

      final spoken = await service.sendPointedImageStream(_image).join();

      expect(spoken, contains('Cậu bé thổi sáo.'));
      expect(spoken, isNot(contains('CHAN_TRAU')));
    });

    test('the introduction is not remembered as something the model said',
        () async {
      final requests = <http.BaseRequest>[];
      final service = AIService(
        apiKey: 'k',
        client: MockClient((request) async {
          requests.add(request);
          return _sseResponse(['LY_NGU\n', 'Chi tiết.']);
        }),
      );

      await service.sendPointedImageStream(_image).join();
      await service.sendPointedImageStream(_image).join();

      final replayed = _textsOf(requests[1]);
      expect(replayed, contains('Chi tiết.'));
      for (final text in replayed) {
        expect(text, isNot(contains('biểu tượng đỉnh cao')));
      }
    });

    test('every request asks for the label, and offers every painting',
        () async {
      String? prompt;
      final service = AIService(
        apiKey: 'k',
        client: MockClient((request) async {
          prompt = _textsOf(request).last;
          return _sseResponse(['KHONG_RO\nChi tiết.']);
        }),
      );

      await service.sendPointedImageStream(_image).join();
      await service.sendPointedImageStream(_image).join();

      for (final painting in kDongHoPaintings) {
        expect(prompt, contains(painting.code));
        expect(prompt, contains(painting.title));
      }
      expect(prompt, contains(AIService.unknownArtworkCode));
    });

    test('the fallback model answers non-streaming', () async {
      final service = AIService(
        apiKey: 'k',
        client: MockClient((request) async {
          if (_modelOf(request) != AIService.fallbackModel.name) {
            return http.Response(_quotaBody(), 429);
          }
          return http.Response(
            _wholeBody('LY_NGU\nChi tiet.'),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

      final spoken = await service.sendPointedImageStream(_image).join();

      expect(spoken, endsWith('Chi tiet.'));
      expect(service.introducedPainting?.code, 'LY_NGU');
    });

    test('forgetIntroduction makes the next capture introduce it again',
        () async {
      final service = AIService(
        apiKey: 'k',
        client: MockClient(
          (request) async => _sseResponse(['LY_NGU\n', 'Chi tiết.']),
        ),
      );

      await service.sendPointedImageStream(_image).join();
      service.forgetIntroduction();
      final again = await service.sendPointedImageStream(_image).join();

      expect(again, contains('Cá chép hóa rồng'));
    });
  });
}
