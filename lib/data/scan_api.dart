import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Talks to Plate One Worker.
///
/// The Gemini key is never here — the app has no credential worth stealing.
/// Every failure is turned into something the UI can say out loud, because the
/// answer to "recognition did not work" is always "build the meal by hand",
/// never a dead end.
class ScanApi {
  ScanApi({
    required this.baseUrl,
    http.Client? client,
    this.timeout = const Duration(seconds: 45),
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;
  final Duration timeout;

  /// Where the API lives. Overridable at build time so a debug build can point
  /// at a local `wrangler dev`.
  static const defaultBaseUrl = String.fromEnvironment(
    'PLATEONE_API',
    defaultValue: 'https://plateone-api.ramy-comm.workers.dev',
  );

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  /// Registers this install. Called once; the token is kept in local storage.
  Future<DeviceRegistration> registerDevice({required String platform}) async {
    final response = await _send(
      () => _client.post(
        _uri('/v1/device'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({'platform': platform}),
      ),
    );
    final body = _decode(response);
    return DeviceRegistration(
      token: body['deviceToken'] as String,
      quota: ScanQuota.fromJson(body['quota'] as Map<String, dynamic>),
    );
  }

  Future<ScanQuota> quota(String deviceToken) async {
    final response = await _send(
      () => _client.get(_uri('/v1/quota'), headers: _auth(deviceToken)),
    );
    return ScanQuota.fromJson(_decode(response));
  }

  /// Sends one already-processed photo for recognition.
  Future<ScanResponse> scan({
    required String deviceToken,
    required Uint8List jpeg,
  }) async {
    final request = http.MultipartRequest('POST', _uri('/v1/scan'))
      ..headers.addAll(_auth(deviceToken))
      // No explicit content type: the filename is enough, and the Worker
      // defaults an untyped part to image/jpeg.
      ..files.add(http.MultipartFile.fromBytes('image', jpeg, filename: 'meal.jpg'));

    final response = await _send(() async {
      final streamed = await _client.send(request);
      return http.Response.fromStream(streamed);
    });
    return ScanResponse.fromJson(_decode(response));
  }

  /// Generates a visual preview of the meal with one addition.
  ///
  /// Sends the addition's **id**, never its name: the server looks the phrase
  /// up in a closed set, so nothing a client sends can reach an image prompt.
  Future<PreviewResult> preview({
    required String deviceToken,
    required Uint8List jpeg,
    required String additionId,
    String? scanId,
  }) async {
    final request = http.MultipartRequest('POST', _uri('/v1/preview'))
      ..headers.addAll(_auth(deviceToken))
      ..fields['additionId'] = additionId
      ..files.add(http.MultipartFile.fromBytes('image', jpeg, filename: 'meal.jpg'));
    if (scanId != null) request.fields['scanId'] = scanId;

    final response = await _send(() async {
      final streamed = await _client.send(request);
      return http.Response.fromStream(streamed);
    }, timeout: const Duration(seconds: 120));
    return PreviewResult.fromJson(_decode(response));
  }

  /// Writes up and draws a plate.
  ///
  /// Sends ids, never words. The engine on the device has already chosen the
  /// addition; this is asking for a sentence and a picture of that decision.
  /// It is the only free-text-free way a model is asked for anything here, and
  /// it is what stops a spoken sentence from steering the picture.
  Future<ChatReply> plate({
    required String deviceToken,
    required List<String> foodIds,
    required String additionId,
  }) async {
    final response = await _send(
      () => _client.post(
        _uri('/v1/plate'),
        headers: {..._auth(deviceToken), 'content-type': 'application/json'},
        body: jsonEncode({'foodIds': foodIds, 'additionId': additionId}),
      ),
      timeout: const Duration(seconds: 90),
    );
    return ChatReply.fromJson(_decode(response));
  }

  /// Downloads a generated preview. Kept on the device only.
  Future<Uint8List> previewImage({
    required String deviceToken,
    required String url,
  }) async {
    final response = await _send(
      () => _client.get(Uri.parse(url), headers: _auth(deviceToken)),
      timeout: const Duration(seconds: 60),
    );
    if (response.statusCode != 200) {
      throw const ScanFailure(ScanError.unknown, 'That preview could not be loaded.');
    }
    return response.bodyBytes;
  }

  /// Files a report against an AI result. Required by Google Play, and it must
  /// never fail in front of the user — so this swallows everything.
  Future<void> report({
    required String deviceToken,
    required String targetType,
    required String targetId,
    required String reason,
    String? note,
  }) async {
    try {
      await _client
          .post(
            _uri('/v1/report'),
            headers: {..._auth(deviceToken), 'content-type': 'application/json'},
            body: jsonEncode({
              'targetType': targetType,
              'targetId': targetId,
              'reason': reason,
              if (note != null && note.isNotEmpty) 'note': note,
            }),
          )
          .timeout(timeout);
    } catch (_) {
      // Reporting something offensive must not itself produce an error.
    }
  }

  /// Backs the "delete my data" promise with a real call.
  Future<void> forgetDevice(String deviceToken) async {
    await _send(() => _client.delete(_uri('/v1/device'), headers: _auth(deviceToken)));
  }

  Map<String, String> _auth(String token) => {'authorization': 'Bearer $token'};

  Future<http.Response> _send(
    Future<http.Response> Function() run, {
    Duration? timeout,
  }) async {
    try {
      return await run().timeout(timeout ?? this.timeout);
    } on ScanFailure {
      rethrow;
    } catch (_) {
      throw const ScanFailure(
        ScanError.offline,
        'No connection. You can still build the meal by hand.',
      );
    }
  }

  Map<String, dynamic> _decode(http.Response response) {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      body = const {};
    }

    if (response.statusCode >= 200 && response.statusCode < 300) return body;

    final code = body['error'] as String? ?? '';
    final message = body['message'] as String? ??
        'Something went wrong. You can still build the meal by hand.';
    throw ScanFailure(ScanError.fromCode(code, response.statusCode), message);
  }

  void close() => _client.close();
}

enum ScanError {
  offline,
  quotaExhausted,
  noFoodFound,
  notAMeal,
  busy,
  rateLimited,
  unauthorized,
  imageRejected,
  previewExpired,
  unknown;

  static ScanError fromCode(String code, int status) => switch (code) {
        'quota_exhausted' => ScanError.quotaExhausted,
        'no_food_found' => ScanError.noFoodFound,
        'not_a_meal' || 'preview_blocked' => ScanError.notAMeal,
        'preview_unavailable' => ScanError.busy,
        'preview_expired' => ScanError.previewExpired,
        'invalid_addition' || 'invalid_food' => ScanError.imageRejected,
        'sign_in_unavailable' => ScanError.busy,
        'chat_unavailable' => ScanError.busy,
        'invalid_field' => ScanError.imageRejected,
        'recognition_busy' => ScanError.busy,
        'rate_limited' => ScanError.rateLimited,
        'unknown_device' || 'unauthorized' => ScanError.unauthorized,
        'image_too_large' ||
        'unsupported_type' ||
        'missing_image' ||
        'empty_image' =>
          ScanError.imageRejected,
        _ => status == 429 ? ScanError.rateLimited : ScanError.unknown,
      };

  /// Whether the user can usefully try the same thing again.
  bool get isRetryable =>
      this == ScanError.busy || this == ScanError.offline || this == ScanError.unknown;

  /// Whether the allowance, rather than the request, is what went wrong.
  bool get isOutOfAllowance => this == ScanError.quotaExhausted;
}

class ScanFailure implements Exception {
  const ScanFailure(this.error, this.message);

  final ScanError error;
  final String message;

  @override
  String toString() => 'ScanFailure(${error.name}: $message)';
}

class DeviceRegistration {
  const DeviceRegistration({required this.token, required this.quota});

  final String token;
  final ScanQuota quota;
}

class ScanQuota {
  const ScanQuota({
    required this.scans,
    required this.previews,
    required this.resetsAt,
  });

  /// What is left today, not what has been spent.
  final int scans;
  final int previews;
  final DateTime resetsAt;

  /// Before the device has ever registered.
  static final unknown = ScanQuota(
    scans: 0,
    previews: 0,
    resetsAt: DateTime.fromMillisecondsSinceEpoch(0),
  );

  bool get hasScans => scans > 0;

  factory ScanQuota.fromJson(Map<String, dynamic> json) => ScanQuota(
        scans: (json['scans'] as num?)?.toInt() ?? 0,
        previews: (json['previews'] as num?)?.toInt() ?? 0,
        resetsAt: DateTime.fromMillisecondsSinceEpoch(
          ((json['resetsAt'] as num?)?.toInt() ?? 0) * 1000,
        ),
      );
}

/// A generated preview, and the label that must travel with it.
class PreviewResult {
  const PreviewResult({
    required this.url,
    required this.disclaimer,
    required this.quota,
  });

  final String url;

  /// Shown with the image, always. Never dismissible.
  final String disclaimer;
  final ScanQuota quota;

  factory PreviewResult.fromJson(Map<String, dynamic> json) => PreviewResult(
        url: json['previewUrl'] as String? ?? '',
        disclaimer: json['disclaimer'] as String? ??
            'AI visual preview — appearance and serving size are illustrative.',
        quota: ScanQuota.fromJson((json['quota'] as Map?)?.cast<String, dynamic>() ?? const {}),
      );
}

class ChatReply {
  const ChatReply({
    required this.messageId,
    required this.reply,
    required this.foodIds,
    required this.additionId,
    this.transcript = '',
    required this.imageUrl,
    required this.disclaimer,
    required this.quota,
  });

  /// What a rating or a report is filed against.
  final String messageId;
  final String reply;
  final List<String> foodIds;

  /// Empty when the model could not choose one, which also means no picture.
  final String additionId;

  /// What the model heard. Empty for a typed turn.
  final String transcript;

  /// Null when the picture could not be drawn. The words still stand.
  final String? imageUrl;

  /// Shown with the image, always. Never dismissible.
  final String disclaimer;
  final ScanQuota quota;

  factory ChatReply.fromJson(Map<String, dynamic> json) => ChatReply(
        messageId: json['messageId'] as String? ?? '',
        reply: json['reply'] as String? ?? '',
        foodIds: ((json['foodIds'] as List?) ?? const [])
            .whereType<String>()
            .toList(growable: false),
        additionId: json['additionId'] as String? ?? '',
        transcript: json['transcript'] as String? ?? '',
        imageUrl: json['imageUrl'] as String?,
        disclaimer: json['disclaimer'] as String? ??
            'AI visual preview — appearance and serving size are illustrative.',
        quota: ScanQuota.fromJson((json['quota'] as Map?)?.cast<String, dynamic>() ?? const {}),
      );
}

/// What one scan produced. `foods` are raw model labels; matching them onto the
/// catalogue happens on the device, in [FoodMatcher].
class ScanResponse {
  const ScanResponse({
    required this.scanId,
    required this.foods,
    required this.components,
    required this.quota,
  });

  final String scanId;
  final List<({String name, double confidence})> foods;
  final MealComponents components;
  final ScanQuota quota;

  factory ScanResponse.fromJson(Map<String, dynamic> json) => ScanResponse(
        scanId: json['scanId'] as String? ?? '',
        foods: ((json['foods'] as List?) ?? const [])
            .map((f) => (
                  name: (f as Map<String, dynamic>)['name'] as String? ?? '',
                  confidence: ((f['confidence'] as num?) ?? 0).toDouble(),
                ))
            .where((f) => f.name.isNotEmpty)
            .toList(),
        components:
            MealComponents.fromJson((json['components'] as Map?)?.cast<String, dynamic>() ?? const {}),
        quota: ScanQuota.fromJson((json['quota'] as Map?)?.cast<String, dynamic>() ?? const {}),
      );
}

/// What the model could and could not see. Advisory only — the rule engine
/// still decides everything from the confirmed food list.
class MealComponents {
  const MealComponents({
    required this.protein,
    required this.fibre,
    required this.healthyFat,
  });

  final ComponentPresence protein;
  final ComponentPresence fibre;
  final ComponentPresence healthyFat;

  factory MealComponents.fromJson(Map<String, dynamic> json) => MealComponents(
        protein: ComponentPresence.fromId(json['protein'] as String?),
        fibre: ComponentPresence.fromId(json['fibre'] as String?),
        healthyFat: ComponentPresence.fromId(json['healthyFat'] as String?),
      );
}

enum ComponentPresence {
  present,
  possiblyMissing,
  uncertain;

  static ComponentPresence fromId(String? id) => switch (id) {
        'present' => ComponentPresence.present,
        'possibly_missing' => ComponentPresence.possiblyMissing,
        _ => ComponentPresence.uncertain,
      };
}
