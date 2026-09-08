import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_discord_presence/dart_discord_presence.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shonenx/core/utils/app_logger.dart';
import 'package:shonenx/shared/models/unified_media.dart';

class DiscordRpcService {
  static const String applicationId = '1435544312296505394';
  static const String _gatewayUrl =
      'wss://gateway.discord.gg/?v=10&encoding=json';
  static const String _appIconUrl =
      'https://raw.githubusercontent.com/roshancodespace/ShonenX/refs/heads/main/assets/images/app_icon.png';
  static const String _defaultAssetKey = 'app_icon';

  final _log = AppLogger.scope(DiscordRpcService);

  DiscordRPC? _discord;
  bool _isDesktopInitialized = false;

  WebSocket? _gatewaySocket;
  Timer? _heartbeatTimer;
  int? _heartbeatInterval;
  int? _sequenceNumber;
  bool _heartbeatAckReceived = true;
  Completer<void>? _connectCompleter;

  String? _token;
  bool _isConnected = false;
  Map<String, dynamic>? _lastPresencePayload;
  DiscordPresence? _lastPresence;

  String? _activeMediaId;
  DateTime? _mediaStartTime;
  DateTime? _browsingStartTime;
  final Map<String, String> _assetCache = {};

  bool get isDesktopPlatform => !kIsWeb && DiscordRPC.isAvailable;

  bool get isConnected =>
      (_discord != null && _discord!.isConnected) || _isConnected;

  Map<String, dynamic>? get lastPresencePayload => _lastPresencePayload;

  Future<void> initDesktopRpc() async {
    if (!isDesktopPlatform || _isDesktopInitialized) return;
    try {
      _log.i('Initializing DiscordRPC for app $applicationId...');
      if (_discord != null) {
        try {
          await _discord!.dispose();
        } catch (_) {}
      }

      final client = DiscordRPC();
      _discord = client;
      final readyCompleter = Completer<void>();

      client.onReady.listen((event) async {
        _log.s('Discord RPC connected as ${event.user.username}');
        if (!readyCompleter.isCompleted) {
          readyCompleter.complete();
        }
        if (_lastPresence != null) {
          try {
            await Future.delayed(const Duration(milliseconds: 200));
            client.setPresence(_lastPresence!);
          } catch (e, s) {
            _log.e('Failed to set presence on ready', e, s);
          }
        }
      });
      client.onError.listen((event) {
        _log.w('Discord RPC error: ${event.message}');
      });
      client.onDisconnected.listen((event) {
        _log.i('Discord RPC disconnected: ${event.message}');
      });

      await client.initialize(applicationId);

      // Wait for Discord IPC onReady to ensure connection is authenticated
      try {
        await readyCompleter.future.timeout(const Duration(seconds: 2));
      } catch (_) {
        _log.w('Discord RPC onReady wait timed out or Discord not running');
      }

      _isDesktopInitialized = true;
      _log.s(
        'DiscordRPC initialized successfully (connected: ${client.isConnected})',
      );
    } on DiscordNotRunningException {
      _log.i('Discord is not running');
    } on DiscordConnectionException catch (e) {
      _log.w('Discord connection failed: ${e.message}');
    } catch (e, s) {
      _log.e('Failed to initialize DiscordRPC', e, s);
    }
  }

  Future<void> connect([String? token]) async {
    if (_connectCompleter != null && !_connectCompleter!.isCompleted) {
      return _connectCompleter!.future;
    }

    _connectCompleter = Completer<void>();
    _token = token;
    _log.i(
      'Connection requested (Token provided: ${token != null && token.isNotEmpty})',
    );

    try {
      if (isDesktopPlatform) {
        if (!_isDesktopInitialized ||
            _discord == null ||
            !_discord!.isConnected) {
          _isDesktopInitialized = false;
          await initDesktopRpc();
        }
      }

      if (token != null && token.isNotEmpty) {
        await _connectGateway();
      }
    } catch (e, s) {
      _log.e('Discord RPC connection error', e, s);
    } finally {
      if (_connectCompleter != null && !_connectCompleter!.isCompleted) {
        _connectCompleter!.complete();
      }
    }
  }

  Future<void> _connectGateway() async {
    _log.i('Connecting to Discord Gateway socket...');
    try {
      await _gatewaySocket?.close();
      _gatewaySocket = await WebSocket.connect(_gatewayUrl);
      _gatewaySocket!.listen(
        _handleGatewayMessage,
        onError: (error) {
          _log.e('Discord Gateway socket error', error);
          if (!isDesktopPlatform) _isConnected = false;
        },
        onDone: () {
          _log.w('Discord Gateway connection closed');
          if (!isDesktopPlatform) _isConnected = false;
          _heartbeatTimer?.cancel();
        },
      );
    } catch (e, s) {
      _log.e('Failed to connect to Discord Gateway', e, s);
    }
  }

  void _handleGatewayMessage(dynamic message) {
    try {
      final data = jsonDecode(message as String);
      final op = data['op'] as int?;
      _sequenceNumber = data['s'] as int?;

      switch (op) {
        case 10:
          _heartbeatInterval = data['d']['heartbeat_interval'] as int?;
          _heartbeatAckReceived = true;
          _log.d('Gateway HELLO received');
          _identify();
          _startHeartbeat();
          break;
        case 0:
          final event = data['t'] as String?;
          if (event == 'READY') {
            _isConnected = true;
            _log.s('Discord Gateway Connected & READY');
            if (_lastPresencePayload != null) {
              _sendGatewayPayload(_lastPresencePayload!);
            } else {
              updateBrowsingPresence();
            }
          }
          break;
        case 11:
          _heartbeatAckReceived = true;
          break;
      }
    } catch (e, s) {
      _log.e('Error handling Gateway message', e, s);
    }
  }

  void _identify() {
    if (_token == null || _token!.isEmpty) return;
    final payload = {
      'op': 2,
      'd': {
        'token': _token,
        'properties': {
          '\$os': Platform.operatingSystem,
          '\$browser': 'ShonenX',
          '\$device': 'ShonenX Client',
        },
        'presence': {'status': 'online', 'afk': false},
      },
    };
    _gatewaySocket?.add(jsonEncode(payload));
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    if (_heartbeatInterval != null) {
      _heartbeatTimer = Timer.periodic(
        Duration(milliseconds: _heartbeatInterval!),
        (_) => _sendHeartbeat(),
      );
    }
  }

  void _sendHeartbeat() {
    if (!_heartbeatAckReceived) {
      _log.w('Heartbeat ACK missed! Reconnecting...');
      if (_token != null) connect(_token!);
      return;
    }
    _heartbeatAckReceived = false;
    final payload = {'op': 1, 'd': _sequenceNumber};
    _gatewaySocket?.add(jsonEncode(payload));
  }

  Future<String> _processImageUrl(String? url) async {
    if (url == null || url.isEmpty) return _defaultAssetKey;
    if (_token == null || _token!.isEmpty) return _defaultAssetKey;
    if (_assetCache.containsKey(url)) return _assetCache[url]!;

    try {
      final response = await http
          .post(
            Uri.parse(
              'https://discord.com/api/v9/applications/$applicationId/external-assets',
            ),
            headers: {
              'Authorization': _token!,
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'urls': [url],
            }),
          )
          .timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        final List data = jsonDecode(response.body);
        if (data.isNotEmpty && data[0]['external_asset_path'] != null) {
          final assetPath = 'mp:${data[0]['external_asset_path']}';
          _assetCache[url] = assetPath;
          return assetPath;
        }
      }
    } catch (e, s) {
      _log.w('Error registering external asset: $url', e, s);
    }

    return _defaultAssetKey;
  }

  DiscordAsset _asset(String? url, {String? text}) {
    final trimmed = url?.trim();
    if (trimmed != null &&
        trimmed.isNotEmpty &&
        trimmed != _appIconUrl &&
        (trimmed.startsWith('http://') || trimmed.startsWith('https://'))) {
      return DiscordAsset(url: trimmed, text: text);
    }
    return DiscordAsset(key: _defaultAssetKey, text: text);
  }

  void _dispatchPresence({
    required DiscordPresence desktopPresence,
    required Map<String, dynamic> gatewayPayload,
  }) {
    _lastPresence = desktopPresence;
    _lastPresencePayload = gatewayPayload;

    if (isDesktopPlatform && _discord != null && _discord!.isConnected) {
      try {
        _log.d('Updating presence via DiscordRPC');
        _discord!.setPresence(desktopPresence);
      } catch (e, s) {
        _log.e('Failed to set desktop presence', e, s);
      }
    }

    if (_gatewaySocket != null && _isConnected) {
      _sendGatewayPayload(gatewayPayload);
    }
  }

  void _sendGatewayPayload(Map<String, dynamic> payload) {
    if (_gatewaySocket != null) {
      _gatewaySocket?.add(jsonEncode(payload));
    }
  }

  Future<void> updateAnimePresence({
    required UnifiedMedia anime,
    required int episodeNumber,
    String? episodeTitle,
    Duration? position,
    Duration? duration,
    int? totalEpisodes,
    bool isPlaying = true,
  }) async {
    _browsingStartTime = null;
    _mediaStartTime = null;

    final title = anime.title.availableTitle;
    final epString =
        'Episode $episodeNumber${totalEpisodes != null ? '/$totalEpisodes' : ''}';
    final baseState = episodeTitle != null && episodeTitle.isNotEmpty
        ? '$epString – $episodeTitle'
        : epString;

    final coverUrl = anime.cover ?? anime.banner;
    final mediaUrl = 'https://anilist.co/anime/${anime.id}';

    DiscordTimestamps? timestamps;
    String stateString = baseState;

    final hasValidDuration = duration != null && duration > Duration.zero;
    final hasValidPosition = position != null && position > Duration.zero;

    if (isPlaying) {
      final now = DateTime.now();
      if (hasValidDuration && hasValidPosition && duration > position) {
        timestamps = DiscordTimestamps.range(
          now.subtract(position),
          now.add(duration - position),
        );
      } else if (hasValidPosition) {
        timestamps = DiscordTimestamps.started(now.subtract(position));
      } else {
        timestamps = DiscordTimestamps.started(now);
      }
    } else {
      final timeDisplay = (hasValidPosition && hasValidDuration)
          ? ' • ${_formatDuration(position)} / ${_formatDuration(duration)}'
          : '';
      stateString = '$baseState$timeDisplay (Paused)';
    }

    _log.i(
      'Updating Anime presence (${isPlaying ? "Playing" : "Paused"}): $title ($stateString)',
    );

    final desktopPresence = DiscordPresence(
      type: DiscordActivityType.watching,
      details: title,
      state: stateString,
      timestamps: timestamps,
      largeAsset: _asset(coverUrl, text: title),
      smallAsset: _asset(_appIconUrl, text: 'ShonenX'),
      statusDisplayType: DiscordStatusDisplayType.details,
    );

    final gatewayPayload = {
      'op': 3,
      'd': {
        'since': null,
        'activities': [
          {
            'application_id': applicationId,
            'name': title,
            'type': 3,
            'details': title,
            'state': stateString,
            if (timestamps?.start != null)
              'timestamps': {
                'start': timestamps!.start! * 1000,
                if (timestamps.end != null) 'end': timestamps.end! * 1000,
              },
            'assets': {
              'large_image': await _processImageUrl(coverUrl),
              'large_text': title,
              'small_image': await _processImageUrl(_appIconUrl),
              'small_text': 'ShonenX',
            },
            'buttons': ['View Anime', 'Watch on ShonenX'],
            'metadata': {
              'button_urls': [
                mediaUrl,
                'https://github.com/roshancodespace/shonenx',
              ],
            },
          },
        ],
        'status': 'online',
        'afk': false,
      },
    };

    _dispatchPresence(
      desktopPresence: desktopPresence,
      gatewayPayload: gatewayPayload,
    );
  }

  Future<void> updateAnimePresencePaused({
    required UnifiedMedia anime,
    required int episodeNumber,
    Duration? position,
    Duration? duration,
    int? timeStampMs,
    int? durationMs,
  }) async {
    final pos =
        position ??
        (timeStampMs != null ? Duration(milliseconds: timeStampMs) : null);
    final dur =
        duration ??
        (durationMs != null ? Duration(milliseconds: durationMs) : null);
    await updateAnimePresence(
      anime: anime,
      episodeNumber: episodeNumber,
      position: pos,
      duration: dur,
      isPlaying: false,
    );
  }

  Future<void> updateMangaPresence({
    required UnifiedMedia manga,
    int? chapterNumber,
    String? chapterTitle,
    int? currentPage,
    int? totalPages,
    int? totalChapters,
  }) async {
    if (_activeMediaId != manga.id || _mediaStartTime == null) {
      _activeMediaId = manga.id;
      _mediaStartTime = DateTime.now();
    }
    _browsingStartTime = null;

    final title = manga.title.availableTitle;
    final chString = chapterNumber != null
        ? 'Chapter $chapterNumber${totalChapters != null ? '/$totalChapters' : ''}'
        : 'Reading';
    final pageString = currentPage != null && totalPages != null
        ? ' • Page $currentPage/$totalPages'
        : '';

    final coverUrl = manga.cover ?? manga.banner;
    final mediaUrl = 'https://anilist.co/manga/${manga.id}';

    _log.i('Updating Manga presence: $title ($chString)');

    final timestamps = DiscordTimestamps.started(_mediaStartTime!);

    final desktopPresence = DiscordPresence(
      type: DiscordActivityType.playing,
      details: title,
      state: '$chString$pageString',
      timestamps: timestamps,
      largeAsset: _asset(coverUrl, text: title),
      smallAsset: _asset(_appIconUrl, text: 'ShonenX'),
      statusDisplayType: DiscordStatusDisplayType.details,
    );

    final gatewayPayload = {
      'op': 3,
      'd': {
        'since': null,
        'activities': [
          {
            'application_id': applicationId,
            'name': title,
            'type': 0,
            'details': title,
            'state': '$chString$pageString',
            'timestamps': {'start': _mediaStartTime!.millisecondsSinceEpoch},
            'assets': {
              'large_image': await _processImageUrl(coverUrl),
              'large_text': title,
              'small_image': await _processImageUrl(_appIconUrl),
              'small_text': 'ShonenX',
            },
            'buttons': ['View Manga', 'Read on ShonenX'],
            'metadata': {
              'button_urls': [
                mediaUrl,
                'https://github.com/roshancodespace/shonenx',
              ],
            },
          },
        ],
        'status': 'online',
        'afk': false,
      },
    };

    _dispatchPresence(
      desktopPresence: desktopPresence,
      gatewayPayload: gatewayPayload,
    );
  }

  Future<void> updateMediaPresence({required UnifiedMedia media}) async {
    if (_activeMediaId != media.id || _mediaStartTime == null) {
      _activeMediaId = media.id;
      _mediaStartTime = DateTime.now();
    }
    _browsingStartTime = null;

    final title = media.title.availableTitle;
    final typeStr = media.type == MediaType.MANGA ? 'Manga' : 'Anime';
    final coverUrl = media.cover ?? media.banner;
    final mediaUrl = 'https://anilist.co/${media.type.id}/${media.id}';

    _log.i('Updating Media presence: $title');

    final timestamps = DiscordTimestamps.started(_mediaStartTime!);

    final desktopPresence = DiscordPresence(
      type: DiscordActivityType.playing,
      details: title,
      state: 'Viewing $typeStr Details',
      timestamps: timestamps,
      largeAsset: _asset(coverUrl, text: title),
      smallAsset: _asset(_appIconUrl, text: 'ShonenX'),
      statusDisplayType: DiscordStatusDisplayType.details,
    );

    final images = await Future.wait([
      _processImageUrl(coverUrl),
      _processImageUrl(_appIconUrl),
    ]);

    final gatewayPayload = {
      'op': 3,
      'd': {
        'since': null,
        'activities': [
          {
            'application_id': applicationId,
            'name': title,
            'type': 0,
            'details': title,
            'state': 'Viewing $typeStr Details',
            'timestamps': {'start': _mediaStartTime!.millisecondsSinceEpoch},
            'assets': {
              'large_image': images[0],
              'large_text': title,
              'small_image': images[1],
              'small_text': 'ShonenX',
            },
            'buttons': ['View $typeStr', 'Get ShonenX'],
            'metadata': {
              'button_urls': [
                mediaUrl,
                'https://github.com/roshancodespace/shonenx',
              ],
            },
          },
        ],
        'status': 'online',
        'afk': false,
      },
    };

    _dispatchPresence(
      desktopPresence: desktopPresence,
      gatewayPayload: gatewayPayload,
    );
  }

  Future<void> updateBrowsingPresence({
    String? activity,
    String? details,
  }) async {
    _browsingStartTime ??= DateTime.now();
    _activeMediaId = null;
    _mediaStartTime = null;

    final act = activity ?? 'Browsing Catalog';
    final det = details ?? 'Exploring Anime & Manga';

    _log.i('Updating Browsing presence: $act');

    final timestamps = DiscordTimestamps.started(_browsingStartTime!);

    final desktopPresence = DiscordPresence(
      type: DiscordActivityType.playing,
      details: act,
      state: det,
      timestamps: timestamps,
      largeAsset: _asset(_appIconUrl, text: 'ShonenX'),
      statusDisplayType: DiscordStatusDisplayType.details,
    );

    final gatewayPayload = {
      'op': 3,
      'd': {
        'since': null,
        'activities': [
          {
            'application_id': applicationId,
            'name': act,
            'type': 0,
            'details': act,
            'state': det,
            'timestamps': {'start': _browsingStartTime!.millisecondsSinceEpoch},
            'assets': {
              'large_image': await _processImageUrl(_appIconUrl),
              'large_text': 'ShonenX - Anime & Manga Client',
            },
            'buttons': ['Get ShonenX'],
            'metadata': {
              'button_urls': ['https://github.com/roshancodespace/shonenx'],
            },
          },
        ],
        'status': 'online',
        'afk': false,
      },
    };

    _dispatchPresence(
      desktopPresence: desktopPresence,
      gatewayPayload: gatewayPayload,
    );
  }

  void resetPresenceState() {
    _lastPresencePayload = null;
    _lastPresence = null;
    _activeMediaId = null;
    _mediaStartTime = null;
    _browsingStartTime = null;
  }

  Future<void> clearPresence() async {
    _log.i('Clearing Discord presence');
    resetPresenceState();
    if (isDesktopPlatform && _discord != null && _discord!.isConnected) {
      try {
        await _discord!.clearPresence();
      } catch (e, s) {
        _log.e('Failed to clear desktop presence', e, s);
      }
    }

    if (_gatewaySocket != null && _isConnected) {
      final payload = {
        'op': 3,
        'd': {
          'since': null,
          'activities': [],
          'status': 'online',
          'afk': false,
        },
      };
      _gatewaySocket?.add(jsonEncode(payload));
    }
  }

  Future<void> disconnect() async {
    _log.i('Disconnecting Discord RPC...');
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    if (_discord != null) {
      try {
        await _discord!.dispose();
      } catch (e, s) {
        _log.e('Failed to disconnect desktop RPC', e, s);
      }
      _discord = null;
      _isDesktopInitialized = false;
    }
    await _gatewaySocket?.close();
    _gatewaySocket = null;
    _sequenceNumber = null;
    _isConnected = false;
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    } else {
      return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
  }
}
