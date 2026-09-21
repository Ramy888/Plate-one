import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Talks to Plate One Worker.
///
/// The Gemini key is never here — the app has no credential worth stealing.
/// Every failure is turned into something the UI can say out loud, because the
/// answer to "recognition did not work" is always "build the meal by hand",
/// never a dead end.
class PlateApi {
  PlateApi({
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
      quota: Allowance.fromJson(body['quota'] as Map<String, dynamic>),
    );
  }

  Future<Allowance> quota(String deviceToken) async {
    final response = await _send(
      () => _client.get(_uri('/v1/quota'), headers: _auth(deviceToken)),
    );
    return Allowance.fromJson(_decode(response));
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

  /// Mints a short-lived token for one voice conversation.
  ///
  /// A browser cannot put an `Authorization` header on a WebSocket, so the
  /// AssemblyAI key stays on the server and this is what the client connects
  /// with. The token is redeemable for a couple of minutes and buys exactly
  /// one session — fetch a fresh one immediately before every connect.
  Future<VoiceToken> voiceToken(String deviceToken) async {
    final response = await _send(
      () => _client.post(_uri('/v1/voice/token'), headers: _auth(deviceToken)),
      timeout: const Duration(seconds: 20),
    );
    return VoiceToken.fromJson(_decode(response));
  }

  /// Describes foods the catalogue does not contain.
  ///
  /// Best effort by design: a plate with an unknown food on it is no worse off
  /// than it was before this existed, so a failure here returns nothing rather
  /// than an error somebody has to read.
  Future<List<DescribedFood>> classify(
    String deviceToken,
    List<String> names,
  ) async {
    if (names.isEmpty) return const [];
    try {
      final response = await _send(
        () => _client.post(
          _uri('/v1/classify'),
          headers: {..._auth(deviceToken), 'content-type': 'application/json'},
          body: jsonEncode({'names': names}),
        ),
      );
      final described =
          (_decode(response)['described'] as List<dynamic>?) ?? const [];
      return described
          .map((raw) => DescribedFood.fromJson(raw as Map<String, dynamic>))
          .where((food) => food.id.isNotEmpty && food.name.isNotEmpty)
          .toList();
    } on ApiFailure {
      return const [];
    }
  }

  /// Ends the day's free try.
  ///
  /// Keeping a plate is the last thing somebody does with one, so it is what
  /// spends the try. The plate itself never leaves the device — this counts,
  /// and only counts.
  Future<Allowance> keepPlate(String deviceToken) async {
    final response = await _send(
      () => _client.post(_uri('/v1/plate/keep'), headers: _auth(deviceToken)),
      timeout: const Duration(seconds: 20),
    );
    return Allowance.fromJson(
      (_decode(response)['quota'] as Map<String, dynamic>?) ?? const {},
    );
  }

  /// Redeems a promo code for more tries.
  Future<PromoResult> redeemPromo({
    required String deviceToken,
    required String code,
  }) async {
    final response = await _send(
      () => _client.post(
        _uri('/v1/promo'),
        headers: {..._auth(deviceToken), 'content-type': 'application/json'},
        body: jsonEncode({'code': code}),
      ),
      timeout: const Duration(seconds: 20),
    );
    final body = _decode(response);
    return PromoResult(
      granted: (body['granted'] as num?)?.toInt() ?? 0,
      quota: Allowance.fromJson(
        (body['quota'] as Map<String, dynamic>?) ?? const {},
      ),
    );
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
      throw const ApiFailure(ApiError.unknown, 'That preview could not be loaded.');
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
    } on ApiFailure {
      rethrow;
    } catch (_) {
      throw const ApiFailure(
        ApiError.offline,
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
    throw ApiFailure(ApiError.fromCode(code, response.statusCode), message);
  }

  void close() => _client.close();
}

enum ApiError {
  offline,
  quotaExhausted,
  busy,
  rateLimited,
  unauthorized,
  pictureExpired,

  /// Today's free plate is used. Not a failure — a door with a key beside it.
  tryUsed,

  /// A promo code that is wrong, or already spent.
  promoRefused,

  /// Something the Worker refused to accept. Always a bug on our side: the
  /// client only ever sends catalogue ids.
  rejected,
  unknown;

  static ApiError fromCode(String code, int status) => switch (code) {
        'try_used' => ApiError.tryUsed,
        'promo_unknown' || 'promo_used' || 'promo_spent' => ApiError.promoRefused,
        'quota_exhausted' => ApiError.quotaExhausted,
        'preview_expired' => ApiError.pictureExpired,
        'plate_unavailable' || 'plate_blocked' => ApiError.busy,
        'invalid_addition' || 'invalid_food' => ApiError.rejected,
        'voice_unavailable' || 'voice_unconfigured' => ApiError.busy,
        'invalid_field' => ApiError.rejected,
        'rate_limited' => ApiError.rateLimited,
        'unknown_device' || 'unauthorized' => ApiError.unauthorized,
        _ => status == 429 ? ApiError.rateLimited : ApiError.unknown,
      };

  /// Whether the user can usefully try the same thing again.
  bool get isRetryable =>
      this == ApiError.busy || this == ApiError.offline || this == ApiError.unknown;

  /// Whether the allowance, rather than the request, is what went wrong.
  bool get isOutOfAllowance => this == ApiError.quotaExhausted;
}

class ApiFailure implements Exception {
  const ApiFailure(this.error, this.message);

  final ApiError error;
  final String message;

  @override
  String toString() => 'ApiFailure(${error.name}: $message)';
}

class DeviceRegistration {
  const DeviceRegistration({required this.token, required this.quota});

  final String token;
  final Allowance quota;
}

class Allowance {
  const Allowance({
    required this.plates,
    required this.previews,
    required this.voice,
    required this.resetsAt,
    this.bonus = false,
  });

  /// Free tries left. A try is the whole journey — talk, be recommended
  /// something, watch it drawn — and keeping the plate is what spends it.
  final int plates;

  /// Pictures. Several go into one try, as the meal fills in and suggestions
  /// are tried, so this is never the number a person thinks about.
  final int previews;

  /// Conversations. Talking is free to us, so this is generous and is really
  /// only here to stop a runaway.
  final int voice;
  final DateTime resetsAt;

  /// Whether any of this came from a redeemed code.
  final bool bonus;

  /// Before the device has ever registered.
  static final unknown = Allowance(
    plates: 0,
    previews: 0,
    voice: 0,
    resetsAt: DateTime.fromMillisecondsSinceEpoch(0),
  );

  bool get hasTry => plates > 0;
  bool get hasVoice => voice > 0;

  factory Allowance.fromJson(Map<String, dynamic> json) => Allowance(
        plates: (json['plates'] as num?)?.toInt() ?? 0,
        previews: (json['previews'] as num?)?.toInt() ?? 0,
        voice: (json['voice'] as num?)?.toInt() ?? 0,
        bonus: json['bonus'] == true,
        resetsAt: DateTime.fromMillisecondsSinceEpoch(
          ((json['resetsAt'] as num?)?.toInt() ?? 0) * 1000,
        ),
      );
}

/// What a redeemed code was worth.
class PromoResult {
  const PromoResult({required this.granted, required this.quota});

  /// How many more tries it opened.
  final int granted;
  final Allowance quota;
}

/// A food the catalogue does not contain, described in the engine's terms.
///
/// The name is the server's, not anything typed here: the client carries the
/// id, and the picture route looks the name up for itself.
class DescribedFood {
  const DescribedFood({
    required this.id,
    required this.name,
    required this.protein,
    required this.fibre,
    required this.fat,
    required this.tags,
    required this.group,
  });

  final String id;
  final String name;
  final int protein;
  final int fibre;
  final int fat;
  final List<String> tags;
  final String group;

  factory DescribedFood.fromJson(Map<String, dynamic> json) => DescribedFood(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        protein: (json['protein'] as num?)?.toInt() ?? 0,
        fibre: (json['fibre'] as num?)?.toInt() ?? 0,
        fat: (json['fat'] as num?)?.toInt() ?? 0,
        tags: ((json['tags'] as List<dynamic>?) ?? const [])
            .map((t) => t.toString())
            .toList(),
        group: json['group'] as String? ?? 'dishes',
      );
}

/// Permission to hold one conversation.
class VoiceToken {
  const VoiceToken({
    required this.token,
    required this.expiresAt,
    required this.maxSessionSeconds,
    required this.quota,
  });

  /// Goes in the WebSocket URL. Never logged, never stored.
  final String token;

  /// After this, connecting fails and a new token is needed.
  final DateTime expiresAt;

  /// The server caps the session at this. The client runs the same clock, so
  /// a forgotten tab stops costing money before the server has to cut it off.
  final int maxSessionSeconds;

  final Allowance quota;

  factory VoiceToken.fromJson(Map<String, dynamic> json) => VoiceToken(
        token: json['token'] as String? ?? '',
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          ((json['expiresAt'] as num?)?.toInt() ?? 0) * 1000,
        ),
        maxSessionSeconds: (json['maxSessionSeconds'] as num?)?.toInt() ?? 600,
        quota: Allowance.fromJson(
          (json['quota'] as Map<String, dynamic>?) ?? const {},
        ),
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
  final Allowance quota;

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
        quota: Allowance.fromJson((json['quota'] as Map?)?.cast<String, dynamic>() ?? const {}),
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
