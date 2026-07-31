import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.ducmanhit.offlinemusic.audio',
      androidNotificationChannelName: 'Cloud Music Offline',
      androidNotificationOngoing: true,
    ).timeout(const Duration(seconds: 3));
  } on Object {
    // Never block launch; the in-app player can still work.
  }
  runApp(const CloudMusicApp());
}

const _bg = Color(0xff080d10);
const _panel = Color(0xff111820);
const _panel2 = Color(0xff17202a);
const _line = Color(0xff25303a);
const _mint = Color(0xff5ce7d2);
const _muted = Color(0xff98a2ad);

enum RepeatMode { off, one, all }

enum LibraryTab { songs, playlists, folders, artists, albums }

enum SortMode { newest, title, artist, played }

class Track {
  Track({
    required this.id,
    required this.title,
    required this.artist,
    required this.path,
    required this.addedAt,
    required this.format,
    required this.fileSize,
    this.durationMs = 0,
    this.favorite = false,
    this.playCount = 0,
    this.lastPlayedAt,
    this.artworkPath,
  });

  final String id;
  String title;
  String artist;
  final String path;
  final DateTime addedAt;
  final String format;
  final int fileSize;
  int durationMs;
  bool favorite;
  int playCount;
  DateTime? lastPlayedAt;
  String? artworkPath;

  int? get bitrateKbps {
    if (durationMs <= 0 || fileSize <= 0) return null;
    return ((fileSize * 8) / (durationMs / 1000) / 1000).round();
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'path': path,
        'addedAt': addedAt.toIso8601String(),
        'format': format,
        'fileSize': fileSize,
        'durationMs': durationMs,
        'favorite': favorite,
        'playCount': playCount,
        'lastPlayedAt': lastPlayedAt?.toIso8601String(),
        'artworkPath': artworkPath,
      };

  factory Track.fromJson(Map<String, dynamic> json) {
    return Track(
      id: json['id'] as String,
      title: json['title'] as String? ?? 'Không tên',
      artist: json['artist'] as String? ?? 'Nghệ sĩ không rõ',
      path: json['path'] as String,
      addedAt: DateTime.tryParse(json['addedAt'] as String? ?? '') ??
          DateTime.now(),
      format: json['format'] as String? ?? 'MP3',
      fileSize: json['fileSize'] as int? ?? 0,
      durationMs: json['durationMs'] as int? ?? 0,
      favorite: json['favorite'] as bool? ?? false,
      playCount: json['playCount'] as int? ?? 0,
      lastPlayedAt: DateTime.tryParse(json['lastPlayedAt'] as String? ?? ''),
      artworkPath: json['artworkPath'] as String?,
    );
  }
}

class SoundPreset {
  const SoundPreset(this.name, this.icon, this.bands);

  final String name;
  final IconData icon;
  final List<double> bands;
}

const _presets = [
  SoundPreset('Flat', Icons.horizontal_rule, [0, 0, 0, 0, 0]),
  SoundPreset('Bass', Icons.waves, [8, 5, 2, 0, -1]),
  SoundPreset('Vocal', Icons.mic, [-2, 1, 6, 3, -1]),
  SoundPreset('Bright', Icons.auto_awesome, [-1, 0, 2, 5, 7]),
  SoundPreset('Night', Icons.nightlight_round, [-4, -2, 1, -1, -5]),
];

const _bandLabels = ['60', '230', '910', '3.6k', '14k'];

class MusicLibrary extends ChangeNotifier {
  static const _tracksKey = 'tracks_v3';
  static const _bandsKey = 'bands_v3';
  static const _soundKey = 'sound_enabled_v3';

  final List<Track> _tracks = [];
  List<double> bands = List<double>.from(_presets.first.bands);
  bool soundProfileEnabled = true;
  bool loaded = false;

  List<Track> get tracks => List.unmodifiable(_tracks);

  List<Track> get recentTracks {
    final recent = _tracks.where((track) => track.lastPlayedAt != null).toList()
      ..sort((a, b) => b.lastPlayedAt!.compareTo(a.lastPlayedAt!));
    return recent.take(12).toList();
  }

  List<Track> get favorites => _tracks.where((track) => track.favorite).toList();

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = prefs.getString(_tracksKey);
      if (encoded != null) {
        final data = jsonDecode(encoded) as List<dynamic>;
        _tracks
          ..clear()
          ..addAll(data
              .map((item) => Track.fromJson(item as Map<String, dynamic>))
              .where((track) => File(track.path).existsSync()));
      }
      final encodedBands = prefs.getString(_bandsKey);
      if (encodedBands != null) {
        bands = (jsonDecode(encodedBands) as List<dynamic>)
            .map((item) => (item as num).toDouble())
            .toList();
      }
      soundProfileEnabled = prefs.getBool(_soundKey) ?? true;
    } finally {
      loaded = true;
      notifyListeners();
    }
  }

  Future<int> importTracks() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['mp3', 'm4a', 'aac', 'wav', 'flac'],
      withData: false,
    );
    if (result == null) return 0;

    var count = 0;
    for (final picked in result.files) {
      final sourcePath = picked.path;
      if (sourcePath == null) continue;
      final source = File(sourcePath);
      if (!source.existsSync()) continue;
      final bytes = await source.readAsBytes();
      final track = await importBytes(picked.name, bytes);
      if (track != null) count++;
    }
    return count;
  }

  Future<Track?> importBytes(String fileName, List<int> bytes) async {
    final extension = _extensionOf(fileName);
    if (!['mp3', 'm4a', 'aac', 'wav', 'flac'].contains(extension)) return null;

    final docs = await getApplicationDocumentsDirectory();
    final musicDir = Directory('${docs.path}/Music');
    await musicDir.create(recursive: true);

    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final target = File('${musicDir.path}/$id.$extension');
    await target.writeAsBytes(bytes, flush: true);
    final duration = await _probeDuration(target.path);

    final track = Track(
      id: id,
      title: _prettyTitle(fileName),
      artist: 'Nghệ sĩ không rõ',
      path: target.path,
      addedAt: DateTime.now(),
      format: extension.toUpperCase(),
      fileSize: bytes.length,
      durationMs: duration.inMilliseconds,
    );
    _tracks.insert(0, track);
    await save();
    notifyListeners();
    return track;
  }

  Future<void> chooseArtwork(Track track) async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.image,
      withData: false,
    );
    if (result == null || result.files.single.path == null) return;

    final source = File(result.files.single.path!);
    if (!source.existsSync()) return;
    final docs = await getApplicationDocumentsDirectory();
    final artDir = Directory('${docs.path}/Artwork');
    await artDir.create(recursive: true);
    final extension = _extensionOf(result.files.single.name);
    final target = File('${artDir.path}/${track.id}.$extension');
    await source.copy(target.path);
    track.artworkPath = target.path;
    await save();
    notifyListeners();
  }

  Future<void> renameTrack(Track track, String title, String artist) async {
    track.title = title.trim().isEmpty ? track.title : title.trim();
    track.artist = artist.trim().isEmpty ? track.artist : artist.trim();
    await save();
    notifyListeners();
  }

  Future<void> toggleFavorite(Track track) async {
    track.favorite = !track.favorite;
    await save();
    notifyListeners();
  }

  Future<void> markPlayed(Track track) async {
    track.playCount += 1;
    track.lastPlayedAt = DateTime.now();
    await save();
    notifyListeners();
  }

  Future<void> removeTrack(Track track) async {
    _tracks.removeWhere((item) => item.id == track.id);
    final file = File(track.path);
    if (file.existsSync()) await file.delete();
    final art = track.artworkPath == null ? null : File(track.artworkPath!);
    if (art != null && art.existsSync()) await art.delete();
    await save();
    notifyListeners();
  }

  Future<void> applyPreset(SoundPreset preset) async {
    bands = List<double>.from(preset.bands);
    soundProfileEnabled = true;
    await save();
    notifyListeners();
  }

  Future<void> setBand(int index, double value) async {
    bands[index] = value;
    await save();
    notifyListeners();
  }

  Future<void> setSoundEnabled(bool value) async {
    soundProfileEnabled = value;
    await save();
    notifyListeners();
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _tracksKey,
      jsonEncode(_tracks.map((track) => track.toJson()).toList()),
    );
    await prefs.setString(_bandsKey, jsonEncode(bands));
    await prefs.setBool(_soundKey, soundProfileEnabled);
  }
}

class MusicPlayer extends ChangeNotifier {
  MusicPlayer(this.library) {
    _player.playerStateStream.listen((state) {
      isPlaying = state.playing;
      notifyListeners();
    });
    _player.positionStream.listen((value) {
      position = value;
      notifyListeners();
    });
    _player.durationStream.listen((value) {
      duration = value ?? Duration.zero;
      notifyListeners();
    });
    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        unawaited(_onComplete());
      }
    });
  }

  final MusicLibrary library;
  final AudioPlayer _player = AudioPlayer();
  int? currentIndex;
  bool isPlaying = false;
  bool shuffle = false;
  RepeatMode repeatMode = RepeatMode.all;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  double speed = 1;
  DateTime? sleepEndsAt;
  Timer? sleepTimer;
  String? lastError;

  Track? get currentTrack {
    final index = currentIndex;
    if (index == null || index < 0 || index >= library.tracks.length) {
      return null;
    }
    return library.tracks[index];
  }

  Future<void> playTrack(int index) async {
    if (library.tracks.isEmpty) return;
    currentIndex = index.clamp(0, library.tracks.length - 1).toInt();
    final track = library.tracks[currentIndex!];
    lastError = null;
    notifyListeners();
    try {
      await _player.setAudioSource(
        AudioSource.uri(
          Uri.file(track.path),
          tag: MediaItem(
            id: track.id,
            album: 'Cloud Music Offline',
            title: track.title,
            artist: track.artist,
            duration: Duration(milliseconds: track.durationMs),
            artUri: track.artworkPath == null ? null : Uri.file(track.artworkPath!),
          ),
        ),
      );
      await _player.setSpeed(speed);
      await _player.play();
      await library.markPlayed(track);
    } catch (_) {
      lastError = 'Không phát được file này';
      notifyListeners();
    }
  }

  Future<void> togglePlay() async {
    if (currentTrack == null && library.tracks.isNotEmpty) {
      await playTrack(0);
      return;
    }
    if (isPlaying) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  Future<void> seek(Duration value) => _player.seek(value);

  Future<void> next() async {
    if (library.tracks.isEmpty) return;
    if (shuffle) {
      await playTrack(Random().nextInt(library.tracks.length));
      return;
    }
    final nextIndex = ((currentIndex ?? -1) + 1) % library.tracks.length;
    await playTrack(nextIndex);
  }

  Future<void> previous() async {
    if (library.tracks.isEmpty) return;
    if (position.inSeconds > 3) {
      await seek(Duration.zero);
      return;
    }
    final previousIndex =
        ((currentIndex ?? 0) - 1 + library.tracks.length) % library.tracks.length;
    await playTrack(previousIndex);
  }

  Future<void> _onComplete() async {
    if (repeatMode == RepeatMode.one) {
      await seek(Duration.zero);
      await _player.play();
      return;
    }
    if (repeatMode == RepeatMode.off &&
        currentIndex == library.tracks.length - 1) {
      await _player.stop();
      return;
    }
    await next();
  }

  void toggleShuffle() {
    shuffle = !shuffle;
    notifyListeners();
  }

  void toggleRepeat() {
    repeatMode = RepeatMode.values[(repeatMode.index + 1) % RepeatMode.values.length];
    notifyListeners();
  }

  Future<void> setSpeed(double value) async {
    speed = value;
    await _player.setSpeed(value);
    notifyListeners();
  }

  void setSleepTimer(Duration? duration) {
    sleepTimer?.cancel();
    if (duration == null) {
      sleepEndsAt = null;
      notifyListeners();
      return;
    }
    sleepEndsAt = DateTime.now().add(duration);
    sleepTimer = Timer(duration, () {
      unawaited(_player.pause());
      sleepEndsAt = null;
      notifyListeners();
    });
    notifyListeners();
  }

  @override
  void dispose() {
    sleepTimer?.cancel();
    _player.dispose();
    super.dispose();
  }
}

class WifiTransferController extends ChangeNotifier {
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;
  MusicLibrary? _library;
  bool running = false;
  String? url;
  String? lastMessage;

  Future<void> start(MusicLibrary library) async {
    if (running) return;
    _library = library;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0, shared: true);
      final ip = await _localIp();
      url = 'http://$ip:${_server!.port}';
      running = true;
      lastMessage = 'Đang nhận nhạc qua WiFi';
      _subscription = _server!.listen((request) {
        unawaited(_handle(request));
      });
      notifyListeners();
    } catch (_) {
      lastMessage = 'Không bật được WiFi transfer';
      notifyListeners();
    }
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    await _server?.close(force: true);
    _subscription = null;
    _server = null;
    running = false;
    url = null;
    lastMessage = 'Đã tắt WiFi transfer';
    notifyListeners();
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.method == 'GET') {
      request.response.headers.contentType = ContentType.html;
      request.response.write(_uploadHtml());
      await request.response.close();
      return;
    }

    if (request.method == 'POST' && request.uri.path == '/upload') {
      final library = _library;
      if (library == null) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
        return;
      }
      var imported = 0;
      try {
        final type = request.headers.contentType;
        final boundary = type?.parameters['boundary'];
        if (boundary == null) throw const FormatException('Missing boundary');
        final parts = MimeMultipartTransformer(boundary).bind(request);
        await for (final part in parts) {
          final disposition = part.headers['content-disposition'] ?? '';
          final name = RegExp(r'filename="([^"]*)"').firstMatch(disposition)?.group(1);
          if (name == null || name.isEmpty) continue;
          final bytes = <int>[];
          await for (final chunk in part) {
            bytes.addAll(chunk);
          }
          final track = await library.importBytes(name, bytes);
          if (track != null) imported++;
        }
        lastMessage = 'Đã nhận $imported bài hát';
        notifyListeners();
        request.response.headers.contentType = ContentType.html;
        request.response.write(_doneHtml(imported));
      } catch (_) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write('Upload failed');
      }
      await request.response.close();
      return;
    }

    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }
}

class AppSettings extends ChangeNotifier {
  static const _puristKey = 'purist_v3';
  static const _normalizeKey = 'normalize_v3';
  static const _notifyKey = 'notify_v3';

  bool puristMode = false;
  bool volumeNormalize = false;
  bool notifications = true;
  bool playbackOpen = true;
  bool notificationOpen = false;
  bool interfaceOpen = false;
  bool wifiOpen = false;
  bool wrappedOpen = false;
  bool storageOpen = false;
  bool languageOpen = false;
  bool accountOpen = false;
  bool aboutOpen = false;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    puristMode = prefs.getBool(_puristKey) ?? false;
    volumeNormalize = prefs.getBool(_normalizeKey) ?? false;
    notifications = prefs.getBool(_notifyKey) ?? true;
    notifyListeners();
  }

  Future<void> setPurist(bool value) async {
    puristMode = value;
    await _save();
  }

  Future<void> setNormalize(bool value) async {
    volumeNormalize = value;
    await _save();
  }

  Future<void> setNotifications(bool value) async {
    notifications = value;
    await _save();
  }

  void toggleSection(String section) {
    switch (section) {
      case 'playback':
        playbackOpen = !playbackOpen;
        break;
      case 'notification':
        notificationOpen = !notificationOpen;
        break;
      case 'interface':
        interfaceOpen = !interfaceOpen;
        break;
      case 'wifi':
        wifiOpen = !wifiOpen;
        break;
      case 'wrapped':
        wrappedOpen = !wrappedOpen;
        break;
      case 'storage':
        storageOpen = !storageOpen;
        break;
      case 'language':
        languageOpen = !languageOpen;
        break;
      case 'account':
        accountOpen = !accountOpen;
        break;
      case 'about':
        aboutOpen = !aboutOpen;
        break;
    }
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_puristKey, puristMode);
    await prefs.setBool(_normalizeKey, volumeNormalize);
    await prefs.setBool(_notifyKey, notifications);
    notifyListeners();
  }
}

class CloudMusicApp extends StatefulWidget {
  const CloudMusicApp({super.key});

  @override
  State<CloudMusicApp> createState() => _CloudMusicAppState();
}

class _CloudMusicAppState extends State<CloudMusicApp> {
  final library = MusicLibrary();
  late final player = MusicPlayer(library);
  final wifi = WifiTransferController();
  final settings = AppSettings();

  @override
  void initState() {
    super.initState();
    unawaited(library.load());
    unawaited(settings.load());
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      library: library,
      player: player,
      wifi: wifi,
      settings: settings,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Cloud Music',
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: _bg,
          colorScheme: ColorScheme.fromSeed(
            seedColor: _mint,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: const HomeShell(),
      ),
    );
  }
}

class AppScope extends InheritedWidget {
  const AppScope({
    required this.library,
    required this.player,
    required this.wifi,
    required this.settings,
    required super.child,
    super.key,
  });

  final MusicLibrary library;
  final MusicPlayer player;
  final WifiTransferController wifi;
  final AppSettings settings;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope not found');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => false;
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int tab = 0;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return AnimatedBuilder(
      animation: Listenable.merge([
        scope.library,
        scope.player,
        scope.wifi,
        scope.settings,
      ]),
      builder: (context, _) {
        final pages = [
          const ForYouPage(),
          const BitPerfectPage(),
          const LibraryPage(),
          const SettingsPage(),
        ];
        return Scaffold(
          body: SafeArea(child: pages[tab]),
          bottomNavigationBar: NavigationBar(
            selectedIndex: tab,
            height: 70,
            onDestinationSelected: (value) => setState(() => tab = value),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.auto_graph),
                selectedIcon: Icon(Icons.auto_graph),
                label: 'Trang chủ',
              ),
              NavigationDestination(
                icon: Icon(Icons.high_quality),
                selectedIcon: Icon(Icons.high_quality),
                label: 'Bit-Perfect',
              ),
              NavigationDestination(
                icon: Icon(Icons.library_music_outlined),
                selectedIcon: Icon(Icons.library_music),
                label: 'Thư viện',
              ),
              NavigationDestination(
                icon: Icon(Icons.verified_outlined),
                selectedIcon: Icon(Icons.verified),
                label: 'Thẩm định',
              ),
            ],
          ),
          bottomSheet: const MiniPlayer(),
        );
      },
    );
  }
}

class ForYouPage extends StatelessWidget {
  const ForYouPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final library = scope.library;
    final player = scope.player;
    final mix = library.tracks.take(10).toList();
    final recent = library.recentTracks.isEmpty ? mix : library.recentTracks;

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 112),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Dành cho bạn',
                style: TextStyle(fontSize: 32, fontWeight: FontWeight.w900),
              ),
            ),
            IconButton(
              tooltip: 'Cài đặt',
              onPressed: () => _openSettings(context),
              icon: const Icon(Icons.settings, size: 30),
            ),
          ],
        ),
        const SizedBox(height: 16),
        SearchBox(
          hint: 'Tìm bài hát, nghệ sĩ, album...',
          onSubmitted: (_) => _openLibrary(context),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: QuickCard(
                icon: Icons.history,
                title: 'Lịch sử nghe',
                onTap: () => _showHistory(context),
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: QuickCard(
                icon: Icons.wifi,
                title: 'Truyền nhạc qua WiFi',
                onTap: () => _openWifi(context),
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: QuickCard(
                icon: Icons.graphic_eq,
                title: 'Bộ chỉnh âm',
                onTap: () => _openEqualizer(context),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _openWrapped(context),
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: _mint,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.auto_awesome, color: Colors.black, size: 34),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text(
                        'Wrapped của bạn',
                        style: TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.w900,
                          fontSize: 18,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Xem lại hành trình nghe nhạc',
                        style: TextStyle(color: Colors.black87),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: Colors.black, size: 30),
              ],
            ),
          ),
        ),
        SectionHeader(
          title: 'Mix hằng ngày',
          onPlayAll: mix.isEmpty ? null : () => player.playTrack(0),
          onShuffle: mix.isEmpty
              ? null
              : () async {
                  player.shuffle = true;
                  await player.next();
                },
        ),
        HorizontalTrackCards(tracks: mix, onTap: (track) => _play(context, track)),
        SectionHeader(
          title: 'Nghe gần đây',
          onPlayAll: recent.isEmpty ? null : () => _play(context, recent.first),
          onShuffle: recent.isEmpty
              ? null
              : () async {
                  player.shuffle = true;
                  await player.next();
                },
        ),
        HorizontalTrackCards(tracks: recent, onTap: (track) => _play(context, track)),
      ],
    );
  }
}

class QuickCard extends StatelessWidget {
  const QuickCard({
    required this.icon,
    required this.title,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        height: 106,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xff0d2222),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xff123131)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: _mint, size: 30),
            const SizedBox(height: 12),
            Text(
              title,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({
    required this.title,
    this.onPlayAll,
    this.onShuffle,
    super.key,
  });

  final String title;
  final VoidCallback? onPlayAll;
  final VoidCallback? onShuffle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 26, bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              TextButton.icon(
                onPressed: onPlayAll,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Phát tất cả'),
              ),
              const SizedBox(width: 12),
              TextButton.icon(
                onPressed: onShuffle,
                icon: const Icon(Icons.shuffle),
                label: const Text('Phát ngẫu nhiên'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class HorizontalTrackCards extends StatelessWidget {
  const HorizontalTrackCards({
    required this.tracks,
    required this.onTap,
    super.key,
  });

  final List<Track> tracks;
  final ValueChanged<Track> onTap;

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) {
      return EmptyPanel(
        icon: Icons.folder_open,
        title: 'Chưa có nhạc',
        subtitle: 'Bấm dấu + trong Thư viện để nhập nhạc.',
      );
    }
    return SizedBox(
      height: 190,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: tracks.length,
        separatorBuilder: (_, __) => const SizedBox(width: 14),
        itemBuilder: (context, index) {
          final track = tracks[index];
          return SizedBox(
            width: 132,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => onTap(track),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ArtworkBox(track: track, size: 132),
                  const SizedBox(height: 10),
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  Text(
                    track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _muted),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class BitPerfectPage extends StatelessWidget {
  const BitPerfectPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final settings = scope.settings;
    final track = scope.player.currentTrack;

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 112),
      children: [
        const Text(
          'Bit-Perfect',
          style: TextStyle(fontSize: 32, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 38),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.diamond, size: 42, color: _muted),
            const SizedBox(width: 22),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'TIÊU CHUẨN',
                    style: TextStyle(
                      color: _muted,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 2,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'EQ, hồ sơ thính lực & chuẩn hoá âm lượng đang bật.',
                    style: TextStyle(color: _muted, fontSize: 16),
                  ),
                ],
              ),
            ),
            Switch(value: settings.puristMode, onChanged: settings.setPurist),
          ],
        ),
        const SizedBox(height: 28),
        const Text(
          'Bit-perfect thật cần DAC USB rời. Khi bật Purist, app ưu tiên đường tín hiệu sạch và tắt các xử lý nghe nhạc trong app.',
          style: TextStyle(color: _muted, fontSize: 16),
        ),
        const Divider(height: 36),
        const SmallLabel('ĐƯỜNG TÍN HIỆU'),
        SignalRow('Equalizer', settings.puristMode ? 'Bỏ qua' : 'Đang bật'),
        SignalRow(
          'Âm lượng (ReplayGain)',
          settings.volumeNormalize ? 'Đang bật' : 'Tắt',
        ),
        SignalRow('Âm lượng', 'Có chỉnh'),
        const Divider(height: 36),
        const SmallLabel('NGUỒN'),
        SignalRow(track == null ? 'Không có bài đang phát' : track.title, '—'),
        const Divider(height: 36),
        const SmallLabel('NGÕ RA'),
        const SignalRow('Không thấy DAC rời', '—'),
      ],
    );
  }
}

class SignalRow extends StatelessWidget {
  const SignalRow(this.label, this.value, {super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: const TextStyle(color: _muted, fontSize: 17)),
          ),
          Text(value, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
        ],
      ),
    );
  }
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  String query = '';
  LibraryTab currentTab = LibraryTab.songs;
  SortMode sortMode = SortMode.newest;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final library = scope.library;
    final player = scope.player;
    final tracks = _tracks(library);

    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.fromLTRB(18, 18, 26, 112),
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Thư viện',
                    style: TextStyle(fontSize: 32, fontWeight: FontWeight.w900),
                  ),
                ),
                IconButton(
                  tooltip: 'Sắp xếp',
                  onPressed: () => _showSort(context),
                  icon: const Icon(Icons.sort),
                ),
                IconButton(
                  tooltip: 'Làm mới',
                  onPressed: () => library.load(),
                  icon: const Icon(Icons.refresh),
                ),
                IconButton(
                  tooltip: 'Thêm nhạc',
                  onPressed: () async {
                    final count = await library.importTracks();
                    if (!context.mounted) return;
                    _toast(context, 'Đã nhập $count bài hát');
                  },
                  icon: const Icon(Icons.add),
                ),
                IconButton(
                  tooltip: 'WiFi',
                  onPressed: () => _openWifi(context),
                  icon: const Icon(Icons.wifi),
                ),
                IconButton(
                  tooltip: 'Cloud',
                  onPressed: () async {
                    final count = await library.importTracks();
                    if (!context.mounted) return;
                    _toast(context, 'Đã nhập $count bài hát');
                  },
                  icon: const Icon(Icons.cloud_outlined),
                ),
                IconButton(
                  tooltip: 'Cài đặt',
                  onPressed: () => _openSettings(context),
                  icon: const Icon(Icons.settings),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SearchBox(
              hint: 'Tìm bài hát, nghệ sĩ, album...',
              onChanged: (value) => setState(() => query = value),
            ),
            const SizedBox(height: 18),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: LibraryTab.values.map((tab) {
                  final selected = currentTab == tab;
                  return Padding(
                    padding: const EdgeInsets.only(right: 22),
                    child: InkWell(
                      onTap: () => setState(() => currentTab = tab),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _tabLabel(tab),
                            style: TextStyle(
                              color: selected ? _mint : _muted,
                              fontSize: 17,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Container(
                            width: selected ? 54 : 0,
                            height: 4,
                            decoration: BoxDecoration(
                              color: _mint,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            const Divider(height: 22),
            if (currentTab == LibraryTab.songs) ...[
              Text(
                '${tracks.length} bài hát',
                style: const TextStyle(color: _muted, fontSize: 16),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: tracks.isEmpty ? null : () => _play(context, tracks.first),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Phát tất cả'),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: tracks.isEmpty
                          ? null
                          : () async {
                              player.shuffle = true;
                              await player.playTrack(Random().nextInt(library.tracks.length));
                            },
                      icon: const Icon(Icons.shuffle),
                      label: const Text('Phát ngẫu nhiên'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              if (tracks.isEmpty)
                EmptyPanel(
                  icon: Icons.music_off,
                  title: 'Chưa có bài hát',
                  subtitle: 'Bấm + để nhập nhạc từ Files, Drive hoặc OneDrive.',
                )
              else
                ...tracks.map(
                  (track) => LibraryTrackRow(
                    track: track,
                    selected: player.currentTrack?.id == track.id,
                    onTap: () => _play(context, track),
                    onMenu: () => _trackMenu(context, track),
                  ),
                ),
            ] else
              _GroupedLibrary(tab: currentTab, tracks: library.tracks),
          ],
        ),
        const Positioned(
          right: 3,
          top: 245,
          bottom: 95,
          child: AlphabetRail(),
        ),
      ],
    );
  }

  List<Track> _tracks(MusicLibrary library) {
    final lower = query.toLowerCase().trim();
    final tracks = library.tracks
        .where((track) =>
            lower.isEmpty ||
            track.title.toLowerCase().contains(lower) ||
            track.artist.toLowerCase().contains(lower))
        .toList();
    switch (sortMode) {
      case SortMode.newest:
        tracks.sort((a, b) => b.addedAt.compareTo(a.addedAt));
        break;
      case SortMode.title:
        tracks.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
        break;
      case SortMode.artist:
        tracks.sort((a, b) => a.artist.toLowerCase().compareTo(b.artist.toLowerCase()));
        break;
      case SortMode.played:
        tracks.sort((a, b) => b.playCount.compareTo(a.playCount));
        break;
    }
    return tracks;
  }

  Future<void> _showSort(BuildContext context) async {
    final selected = await showModalBottomSheet<SortMode>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.schedule),
              title: const Text('Mới nhất'),
              onTap: () => Navigator.pop(context, SortMode.newest),
            ),
            ListTile(
              leading: const Icon(Icons.title),
              title: const Text('Tên bài hát'),
              onTap: () => Navigator.pop(context, SortMode.title),
            ),
            ListTile(
              leading: const Icon(Icons.person),
              title: const Text('Nghệ sĩ'),
              onTap: () => Navigator.pop(context, SortMode.artist),
            ),
            ListTile(
              leading: const Icon(Icons.trending_up),
              title: const Text('Nghe nhiều'),
              onTap: () => Navigator.pop(context, SortMode.played),
            ),
          ],
        ),
      ),
    );
    if (selected != null) {
      setState(() => sortMode = selected);
    }
  }
}

class LibraryTrackRow extends StatelessWidget {
  const LibraryTrackRow({
    required this.track,
    required this.selected,
    required this.onTap,
    required this.onMenu,
    super.key,
  });

  final Track track;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: ArtworkBox(track: track, size: 58),
      title: Text(
        track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: FontWeight.w900,
          color: selected ? _mint : Colors.white,
        ),
      ),
      subtitle: Text(
        '${track.artist} • ${track.format}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: _muted),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_trackDuration(track), style: const TextStyle(color: _muted)),
          IconButton(onPressed: onMenu, icon: const Icon(Icons.more_vert)),
        ],
      ),
      onTap: onTap,
    );
  }
}

class _GroupedLibrary extends StatelessWidget {
  const _GroupedLibrary({required this.tab, required this.tracks});

  final LibraryTab tab;
  final List<Track> tracks;

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) {
      return EmptyPanel(
        icon: Icons.folder_open,
        title: 'Trống',
        subtitle: 'Nhập nhạc trước để tạo ${_tabLabel(tab).toLowerCase()}.',
      );
    }

    final values = <String, int>{};
    for (final track in tracks) {
      final key = switch (tab) {
        LibraryTab.playlists => track.favorite ? 'Yêu thích' : 'Tất cả nhạc',
        LibraryTab.folders => 'Nhạc offline',
        LibraryTab.artists => track.artist,
        LibraryTab.albums => 'Cloud Music Offline',
        LibraryTab.songs => 'Bài hát',
      };
      values[key] = (values[key] ?? 0) + 1;
    }

    return Column(
      children: values.entries.map((entry) {
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: _panel,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _line),
          ),
          child: ListTile(
            leading: Icon(_tabIcon(tab), color: _mint),
            title: Text(entry.key),
            subtitle: Text('${entry.value} bài hát'),
            trailing: const Icon(Icons.chevron_right),
          ),
        );
      }).toList(),
    );
  }
}

class AlphabetRail extends StatelessWidget {
  const AlphabetRail({super.key});

  @override
  Widget build(BuildContext context) {
    const letters = ['#', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z'];
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: letters
          .map(
            (letter) => Text(
              letter,
              style: TextStyle(
                color: ['D', 'N', 'S', 'T'].contains(letter) ? _mint : Colors.white24,
                fontSize: 11,
                fontWeight: FontWeight.w900,
              ),
            ),
          )
          .toList(),
    );
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final settings = scope.settings;
    final library = scope.library;
    final player = scope.player;

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 112),
      children: [
        const Text(
          'Cài đặt',
          style: TextStyle(fontSize: 32, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 24),
        SettingRow(
          icon: Icons.local_cafe,
          title: 'Mời cà phê',
          subtitle: 'Mở hết giao diện, bỏ giới hạn & quảng cáo · 119.000đ',
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _toast(context, 'Bản này đã mở miễn phí cho bạn'),
        ),
        SettingSection(
          icon: Icons.play_circle_outline,
          title: 'Phát nhạc',
          open: settings.playbackOpen,
          onTap: () => settings.toggleSection('playback'),
          children: [
            SettingRow(
              icon: Icons.nightlight_round,
              title: 'Hẹn giờ tắt nhạc',
              subtitle: player.sleepEndsAt == null ? 'Tắt' : 'Đang bật',
              onTap: () => _showSleepTimer(context, player),
            ),
            SettingRow(
              icon: Icons.graphic_eq,
              title: 'Chuẩn hoá âm lượng',
              subtitle: settings.volumeNormalize ? 'Bật' : 'Tắt',
              trailing: Switch(
                value: settings.volumeNormalize,
                onChanged: settings.setNormalize,
              ),
            ),
            SettingRow(
              icon: Icons.diamond,
              title: 'Chế độ Purist',
              subtitle: 'Bỏ qua EQ, hồ sơ thính lực & chuẩn hoá âm lượng.',
              trailing: Switch(value: settings.puristMode, onChanged: settings.setPurist),
            ),
          ],
        ),
        SettingSection(
          icon: Icons.notifications_outlined,
          title: 'Thông báo',
          open: settings.notificationOpen,
          onTap: () => settings.toggleSection('notification'),
          children: [
            SettingRow(
              icon: Icons.notifications_active,
              title: 'Thông báo phát nhạc',
              subtitle: settings.notifications ? 'Bật' : 'Tắt',
              trailing: Switch(
                value: settings.notifications,
                onChanged: settings.setNotifications,
              ),
            ),
          ],
        ),
        SettingSection(
          icon: Icons.palette_outlined,
          title: 'Giao diện',
          open: settings.interfaceOpen,
          onTap: () => settings.toggleSection('interface'),
          children: const [
            SettingRow(
              icon: Icons.dark_mode,
              title: 'Giao diện',
              subtitle: 'Tối, màu nhấn xanh mint.',
            ),
          ],
        ),
        SettingSection(
          icon: Icons.wifi,
          title: 'Truyền nhạc qua WiFi',
          open: settings.wifiOpen,
          onTap: () => settings.toggleSection('wifi'),
          children: [
            SettingRow(
              icon: Icons.upload_file,
              title: 'Truyền nhạc qua WiFi',
              subtitle: scope.wifi.running ? scope.wifi.url ?? 'Đang bật' : 'Thêm nhạc từ máy tính qua WiFi.',
              onTap: () => _openWifi(context),
            ),
          ],
        ),
        SettingSection(
          icon: Icons.auto_awesome,
          title: 'Wrapped',
          open: settings.wrappedOpen,
          onTap: () => settings.toggleSection('wrapped'),
          children: [
            SettingRow(
              icon: Icons.insights,
              title: 'Wrapped của bạn',
              subtitle: '${library.tracks.length} bài, ${library.recentTracks.length} bài đã nghe gần đây.',
              onTap: () => _openWrapped(context),
            ),
          ],
        ),
        SettingSection(
          icon: Icons.storage,
          title: 'Bộ nhớ',
          open: settings.storageOpen,
          onTap: () => settings.toggleSection('storage'),
          children: [
            SettingRow(
              icon: Icons.sd_storage,
              title: 'Nhạc offline',
              subtitle: '${library.tracks.length} bài · ${_bytes(library.tracks.fold<int>(0, (sum, track) => sum + track.fileSize))}',
            ),
          ],
        ),
        SettingSection(
          icon: Icons.language,
          title: 'Ngôn ngữ',
          open: settings.languageOpen,
          onTap: () => settings.toggleSection('language'),
          children: const [
            SettingRow(
              icon: Icons.translate,
              title: 'Tiếng Việt',
              subtitle: 'Giao diện hiện tại.',
            ),
          ],
        ),
        SettingSection(
          icon: Icons.account_circle_outlined,
          title: 'Tài khoản',
          open: settings.accountOpen,
          onTap: () => settings.toggleSection('account'),
          children: const [
            SettingRow(
              icon: Icons.person,
              title: 'Offline mode',
              subtitle: 'Không cần đăng nhập.',
            ),
          ],
        ),
        SettingSection(
          icon: Icons.info_outline,
          title: 'Giới thiệu',
          open: settings.aboutOpen,
          onTap: () => settings.toggleSection('about'),
          children: const [
            SettingRow(
              icon: Icons.music_note,
              title: 'Cloud Music Offline',
              subtitle: 'Nghe nhạc offline, ký IPA bằng eSign.',
            ),
          ],
        ),
      ],
    );
  }
}

class SettingSection extends StatelessWidget {
  const SettingSection({
    required this.icon,
    required this.title,
    required this.open,
    required this.onTap,
    required this.children,
    super.key,
  });

  final IconData icon;
  final String title;
  final bool open;
  final VoidCallback onTap;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SettingRow(
          icon: icon,
          title: title,
          trailing: Icon(open ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down),
          onTap: onTap,
          strong: true,
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.only(left: 38),
            child: Column(children: children),
          ),
      ],
    );
  }
}

class SettingRow extends StatelessWidget {
  const SettingRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.strong = false,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: _mint, size: 30),
      title: Text(
        title,
        style: TextStyle(
          fontSize: strong ? 21 : 19,
          fontWeight: strong ? FontWeight.w900 : FontWeight.w700,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, style: const TextStyle(color: Colors.white70, fontSize: 16)),
      trailing: trailing,
      onTap: onTap,
    );
  }
}

class FullPlayerPage extends StatelessWidget {
  const FullPlayerPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final library = scope.library;
    final player = scope.player;
    final track = player.currentTrack;
    final duration = player.duration.inMilliseconds <= 0
        ? const Duration(seconds: 1)
        : player.duration;
    final progress =
        duration.inMilliseconds <= 0 ? 0.0 : player.position.inMilliseconds / duration.inMilliseconds;

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 26),
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Đóng',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.keyboard_arrow_down, size: 34),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Bit-Perfect',
                  onPressed: () => _toast(context, 'Xem ở tab Bit-Perfect'),
                  icon: const Icon(Icons.diamond),
                ),
                IconButton(
                  tooltip: 'Lời nhạc',
                  onPressed: () => _toast(context, 'Chưa có lời nhạc trong file offline'),
                  icon: const Icon(Icons.queue_music),
                ),
                IconButton(
                  tooltip: 'Sửa thông tin',
                  onPressed: track == null ? null : () => _renameTrack(context, library, track),
                  icon: const Icon(Icons.edit),
                ),
                IconButton(
                  tooltip: 'Bộ chỉnh âm',
                  onPressed: () => _openEqualizer(context),
                  icon: const Icon(Icons.graphic_eq, color: _mint),
                ),
                IconButton(
                  tooltip: 'Chia sẻ',
                  onPressed: () => _toast(context, 'Có thể chia sẻ file bằng app Files/eSign'),
                  icon: const Icon(Icons.share),
                ),
                IconButton(
                  tooltip: 'Thêm',
                  onPressed: track == null ? null : () => _trackMenu(context, track),
                  icon: const Icon(Icons.more_vert),
                ),
              ],
            ),
            const SizedBox(height: 42),
            Center(child: ArtworkBox(track: track, size: min(MediaQuery.sizeOf(context).width * 0.68, 330))),
            const SizedBox(height: 32),
            Text(
              track?.title ?? 'Chọn một bài hát',
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            Text(
              track?.artist ?? 'Thư viện offline của bạn',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 17),
            ),
            const SizedBox(height: 16),
            if (track != null)
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  InfoChip('${(player.currentIndex ?? 0) + 1}/${library.tracks.length}'),
                  InfoChip(track.format),
                  InfoChip('${track.bitrateKbps ?? 0} kbps', highlighted: true),
                  InfoChip(_bytes(track.fileSize)),
                ],
              ),
            if (track != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: _panel,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: _muted),
                ),
              ),
            ],
            const SizedBox(height: 26),
            WaveformProgress(progress: progress.clamp(0, 1).toDouble()),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_formatDuration(player.position), style: const TextStyle(color: _muted)),
                Text(_formatDuration(player.duration), style: const TextStyle(color: _muted)),
              ],
            ),
            const SizedBox(height: 18),
            Slider(
              value: min(player.position.inMilliseconds.toDouble(), duration.inMilliseconds.toDouble()),
              min: 0,
              max: duration.inMilliseconds.toDouble(),
              onChanged: track == null
                  ? null
                  : (value) => player.seek(Duration(milliseconds: value.round())),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  tooltip: 'Ngẫu nhiên',
                  iconSize: 31,
                  onPressed: player.toggleShuffle,
                  icon: Icon(Icons.shuffle, color: player.shuffle ? _mint : _muted),
                ),
                IconButton(
                  tooltip: 'Trước',
                  iconSize: 39,
                  onPressed: player.previous,
                  icon: const Icon(Icons.skip_previous),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    shape: const CircleBorder(),
                    fixedSize: const Size(86, 86),
                    backgroundColor: _mint,
                    foregroundColor: Colors.black,
                  ),
                  onPressed: player.togglePlay,
                  child: Icon(player.isPlaying ? Icons.pause : Icons.play_arrow, size: 46),
                ),
                IconButton(
                  tooltip: 'Sau',
                  iconSize: 39,
                  onPressed: player.next,
                  icon: const Icon(Icons.skip_next),
                ),
                IconButton(
                  tooltip: 'Lặp lại',
                  iconSize: 31,
                  onPressed: player.toggleRepeat,
                  icon: Icon(
                    player.repeatMode == RepeatMode.one ? Icons.repeat_one : Icons.repeat,
                    color: player.repeatMode == RepeatMode.off ? _muted : _mint,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                IconButton(
                  tooltip: 'Yêu thích',
                  iconSize: 34,
                  onPressed: track == null ? null : () => library.toggleFavorite(track),
                  icon: Icon(track?.favorite == true ? Icons.favorite : Icons.favorite_border),
                ),
                IconButton(
                  tooltip: 'AirPlay',
                  iconSize: 34,
                  onPressed: () => _toast(context, 'Chọn AirPods trong Control Center của iOS'),
                  icon: const Icon(Icons.airplay),
                ),
                IconButton(
                  tooltip: 'Hẹn giờ',
                  iconSize: 34,
                  onPressed: () => _showSleepTimer(context, player),
                  icon: const Icon(Icons.nightlight_round),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class EqualizerPage extends StatelessWidget {
  const EqualizerPage({super.key});

  @override
  Widget build(BuildContext context) {
    final library = AppScope.of(context).library;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bộ chỉnh âm'),
        backgroundColor: _bg,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Equalizer',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900),
                ),
              ),
              Switch(
                value: library.soundProfileEnabled,
                onChanged: library.setSoundEnabled,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: _presets.map((preset) {
              final active = _sameBands(library.bands, preset.bands);
              return ChoiceChip(
                avatar: Icon(preset.icon, size: 18),
                label: Text(preset.name),
                selected: active,
                onSelected: (_) => library.applyPreset(preset),
              );
            }).toList(),
          ),
          const SizedBox(height: 24),
          Container(
            height: 380,
            padding: const EdgeInsets.fromLTRB(8, 16, 8, 10),
            decoration: BoxDecoration(
              color: _panel,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _line),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: List.generate(_bandLabels.length, (index) {
                return Column(
                  children: [
                    Text('${library.bands[index].round()} dB'),
                    Expanded(
                      child: RotatedBox(
                        quarterTurns: -1,
                        child: Slider(
                          value: library.bands[index],
                          min: -12,
                          max: 12,
                          divisions: 24,
                          onChanged: library.soundProfileEnabled
                              ? (value) => library.setBand(index, value)
                              : null,
                        ),
                      ),
                    ),
                    Text(_bandLabels[index], style: const TextStyle(color: _muted)),
                  ],
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}

class WifiTransferPage extends StatelessWidget {
  const WifiTransferPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final wifi = scope.wifi;

    return Scaffold(
      appBar: AppBar(title: const Text('Truyền nhạc qua WiFi'), backgroundColor: _bg),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          const Icon(Icons.wifi, color: _mint, size: 70),
          const SizedBox(height: 18),
          const Text(
            'Thêm nhạc từ máy tính',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 25, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 10),
          Text(
            wifi.running
                ? 'Mở địa chỉ này trên trình duyệt máy tính cùng WiFi:'
                : 'Bật máy chủ WiFi rồi mở link trên máy tính cùng mạng.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: _muted),
          ),
          const SizedBox(height: 22),
          if (wifi.url != null)
            SelectableText(
              wifi.url!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _mint, fontSize: 22, fontWeight: FontWeight.w900),
            ),
          const SizedBox(height: 22),
          FilledButton.icon(
            onPressed: wifi.running
                ? wifi.stop
                : () async {
                    await wifi.start(scope.library);
                  },
            icon: Icon(wifi.running ? Icons.stop : Icons.play_arrow),
            label: Text(wifi.running ? 'Tắt WiFi transfer' : 'Bật WiFi transfer'),
          ),
          if (wifi.lastMessage != null) ...[
            const SizedBox(height: 14),
            Text(wifi.lastMessage!, textAlign: TextAlign.center, style: const TextStyle(color: _muted)),
          ],
        ],
      ),
    );
  }
}

class WrappedPage extends StatelessWidget {
  const WrappedPage({super.key});

  @override
  Widget build(BuildContext context) {
    final library = AppScope.of(context).library;
    final plays = library.tracks.fold<int>(0, (sum, track) => sum + track.playCount);
    final minutes = library.tracks.fold<int>(
      0,
      (sum, track) => sum + (track.durationMs * track.playCount ~/ 60000),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Wrapped của bạn'), backgroundColor: _bg),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: _mint,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.auto_awesome, color: Colors.black, size: 48),
                const SizedBox(height: 16),
                const Text(
                  'Hành trình nghe nhạc',
                  style: TextStyle(color: Colors.black, fontSize: 26, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 8),
                Text('$plays lượt nghe · $minutes phút · ${library.favorites.length} yêu thích',
                    style: const TextStyle(color: Colors.black87)),
              ],
            ),
          ),
          const SizedBox(height: 18),
          ...library.recentTracks.take(8).map(
                (track) => LibraryTrackRow(
                  track: track,
                  selected: false,
                  onTap: () => _play(context, track),
                  onMenu: () => _trackMenu(context, track),
                ),
              ),
        ],
      ),
    );
  }
}

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final player = AppScope.of(context).player;
    final track = player.currentTrack;
    if (track == null) return const SizedBox.shrink();

    return Material(
      color: const Color(0xff0d1218),
      child: SafeArea(
        top: false,
        child: InkWell(
          onTap: () => _openPlayer(context),
          child: Container(
            height: 74,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: _line)),
            ),
            child: Row(
              children: [
                ArtworkBox(track: track, size: 48),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                      Text(
                        _formatDuration(player.position),
                        style: const TextStyle(color: _muted),
                      ),
                    ],
                  ),
                ),
                IconButton(onPressed: player.previous, icon: const Icon(Icons.skip_previous)),
                IconButton.filled(
                  onPressed: player.togglePlay,
                  icon: Icon(player.isPlaying ? Icons.pause : Icons.play_arrow),
                ),
                IconButton(onPressed: player.next, icon: const Icon(Icons.skip_next)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SearchBox extends StatelessWidget {
  const SearchBox({
    required this.hint,
    this.onChanged,
    this.onSubmitted,
    super.key,
  });

  final String hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextField(
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: _muted),
        prefixIcon: const Icon(Icons.search, size: 30),
        filled: true,
        fillColor: _panel2,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(30),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 18),
      ),
    );
  }
}

class ArtworkBox extends StatelessWidget {
  const ArtworkBox({required this.track, required this.size, super.key});

  final Track? track;
  final double size;

  @override
  Widget build(BuildContext context) {
    final artwork = track?.artworkPath;
    final file = artwork == null ? null : File(artwork);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: size,
        height: size,
        child: file != null && file.existsSync()
            ? Image.file(file, fit: BoxFit.cover)
            : Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: _artColors(track?.title ?? 'Cloud Music'),
                  ),
                ),
                child: Center(
                  child: Icon(Icons.music_note, color: Colors.white, size: size * 0.36),
                ),
              ),
      ),
    );
  }
}

class InfoChip extends StatelessWidget {
  const InfoChip(this.text, {this.highlighted = false, super.key});

  final String text;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: highlighted ? const Color(0xff113a36) : _panel,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: TextStyle(color: highlighted ? _mint : _muted)),
    );
  }
}

class WaveformProgress extends StatelessWidget {
  const WaveformProgress({required this.progress, super.key});

  final double progress;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 86,
      child: CustomPaint(
        painter: _WavePainter(progress),
        size: Size.infinite,
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  const _WavePainter(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final played = Paint()
      ..color = _mint
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 5;
    final rest = Paint()
      ..color = const Color(0xff303741)
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 5;
    const count = 56;
    final gap = size.width / count;
    for (var i = 0; i < count; i++) {
      final t = i / count;
      final h = (sin(i * 0.72).abs() * 0.65 + 0.22) * size.height;
      final x = i * gap + gap / 2;
      final y1 = (size.height - h) / 2;
      final y2 = y1 + h;
      canvas.drawLine(Offset(x, y1), Offset(x, y2), t <= progress ? played : rest);
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}

class EmptyPanel extends StatelessWidget {
  const EmptyPanel({
    required this.icon,
    required this.title,
    required this.subtitle,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 42, horizontal: 18),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _line),
      ),
      child: Column(
        children: [
          Icon(icon, color: _mint, size: 44),
          const SizedBox(height: 12),
          Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
          const SizedBox(height: 6),
          Text(subtitle, textAlign: TextAlign.center, style: const TextStyle(color: _muted)),
        ],
      ),
    );
  }
}

class SmallLabel extends StatelessWidget {
  const SmallLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: _muted,
        fontWeight: FontWeight.w900,
        letterSpacing: 3,
      ),
    );
  }
}

Future<void> _play(BuildContext context, Track track) async {
  final scope = AppScope.of(context);
  final index = scope.library.tracks.indexWhere((item) => item.id == track.id);
  if (index < 0) return;
  await scope.player.playTrack(index);
  if (context.mounted) _openPlayer(context);
}

void _openPlayer(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const FullPlayerPage()));
}

void _openLibrary(BuildContext context) {
  _toast(context, 'Mở tab Thư viện để tìm kiếm đầy đủ');
}

void _openSettings(BuildContext context) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => const Scaffold(
        body: SafeArea(child: SettingsPage()),
      ),
    ),
  );
}

void _openEqualizer(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EqualizerPage()));
}

void _openWifi(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const WifiTransferPage()));
}

void _openWrapped(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const WrappedPage()));
}

void _showHistory(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const WrappedPage()));
}

Future<void> _trackMenu(BuildContext context, Track track) async {
  final library = AppScope.of(context).library;
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            leading: const Icon(Icons.favorite_border),
            title: const Text('Yêu thích'),
            onTap: () => Navigator.pop(context, 'favorite'),
          ),
          ListTile(
            leading: const Icon(Icons.edit),
            title: const Text('Sửa tên/nghệ sĩ'),
            onTap: () => Navigator.pop(context, 'rename'),
          ),
          ListTile(
            leading: const Icon(Icons.image),
            title: const Text('Chọn ảnh bìa'),
            onTap: () => Navigator.pop(context, 'artwork'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Xoá file offline'),
            onTap: () => Navigator.pop(context, 'delete'),
          ),
        ],
      ),
    ),
  );
  if (!context.mounted) return;
  if (choice == 'favorite') await library.toggleFavorite(track);
  if (choice == 'rename') await _renameTrack(context, library, track);
  if (choice == 'artwork') await library.chooseArtwork(track);
  if (choice == 'delete') await library.removeTrack(track);
}

Future<void> _renameTrack(
  BuildContext context,
  MusicLibrary library,
  Track track,
) async {
  final titleController = TextEditingController(text: track.title);
  final artistController = TextEditingController(text: track.artist);
  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Sửa thông tin'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(controller: titleController, decoration: const InputDecoration(labelText: 'Tên bài hát')),
          TextField(controller: artistController, decoration: const InputDecoration(labelText: 'Nghệ sĩ')),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Huỷ')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Lưu')),
      ],
    ),
  );
  if (saved == true) {
    await library.renameTrack(track, titleController.text, artistController.text);
  }
}

Future<void> _showSleepTimer(BuildContext context, MusicPlayer player) async {
  final selected = await showModalBottomSheet<Duration?>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(leading: const Icon(Icons.timer_off), title: const Text('Tắt'), onTap: () => Navigator.pop(context)),
          ListTile(leading: const Icon(Icons.timer), title: const Text('15 phút'), onTap: () => Navigator.pop(context, const Duration(minutes: 15))),
          ListTile(leading: const Icon(Icons.timer), title: const Text('30 phút'), onTap: () => Navigator.pop(context, const Duration(minutes: 30))),
          ListTile(leading: const Icon(Icons.timer), title: const Text('45 phút'), onTap: () => Navigator.pop(context, const Duration(minutes: 45))),
          ListTile(leading: const Icon(Icons.timer), title: const Text('60 phút'), onTap: () => Navigator.pop(context, const Duration(hours: 1))),
        ],
      ),
    ),
  );
  player.setSleepTimer(selected);
}

void _toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

String _tabLabel(LibraryTab tab) {
  switch (tab) {
    case LibraryTab.songs:
      return 'Bài hát';
    case LibraryTab.playlists:
      return 'Playlist';
    case LibraryTab.folders:
      return 'Thư mục';
    case LibraryTab.artists:
      return 'Nghệ sĩ';
    case LibraryTab.albums:
      return 'Album';
  }
}

IconData _tabIcon(LibraryTab tab) {
  switch (tab) {
    case LibraryTab.songs:
      return Icons.music_note;
    case LibraryTab.playlists:
      return Icons.playlist_play;
    case LibraryTab.folders:
      return Icons.folder;
    case LibraryTab.artists:
      return Icons.person;
    case LibraryTab.albums:
      return Icons.album;
  }
}

String _trackDuration(Track track) {
  if (track.durationMs <= 0) return '--:--';
  return _formatDuration(Duration(milliseconds: track.durationMs));
}

String _formatDuration(Duration duration) {
  if (duration <= Duration.zero) return '0:00';
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60).toString();
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (hours > 0) return '$hours:${minutes.padLeft(2, '0')}:$seconds';
  return '$minutes:$seconds';
}

String _bytes(int bytes) {
  if (bytes <= 0) return '0 MB';
  final mb = bytes / (1024 * 1024);
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  return '${(mb / 1024).toStringAsFixed(1)} GB';
}

String _prettyTitle(String name) {
  return name
      .replaceAll(RegExp(r'\.[^.]+$'), '')
      .replaceAll(RegExp(r'[_-]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String _extensionOf(String name) {
  final parts = name.split('.');
  if (parts.length < 2) return 'mp3';
  return parts.last.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
}

Future<Duration> _probeDuration(String path) async {
  final player = AudioPlayer();
  try {
    return await player.setFilePath(path).timeout(const Duration(seconds: 5)) ??
        Duration.zero;
  } catch (_) {
    return Duration.zero;
  } finally {
    await player.dispose();
  }
}

bool _sameBands(List<double> a, List<double> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if ((a[i] - b[i]).abs() > 0.1) return false;
  }
  return true;
}

List<Color> _artColors(String seed) {
  final hash = seed.codeUnits.fold<int>(0, (value, unit) => value + unit);
  final palettes = [
    [const Color(0xffff86c8), const Color(0xff8e7bff)],
    [const Color(0xfff2694b), const Color(0xff211a4d)],
    [const Color(0xff64e9cc), const Color(0xff234a88)],
    [const Color(0xffffc857), const Color(0xff6a3de8)],
    [const Color(0xff9be15d), const Color(0xff00a896)],
  ];
  return palettes[hash % palettes.length];
}

Future<String> _localIp() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
  );
  if (interfaces.isEmpty) return '127.0.0.1';
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      final ip = address.address;
      if (ip.startsWith('192.168.') || ip.startsWith('10.') || ip.startsWith('172.')) {
        return ip;
      }
    }
  }
  final addresses = interfaces.expand((item) => item.addresses).toList();
  return addresses.isEmpty ? '127.0.0.1' : addresses.first.address;
}

String _uploadHtml() {
  return '''
<!doctype html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#080d10;color:white;padding:24px}
.box{max-width:520px;margin:auto;background:#111820;border:1px solid #25303a;border-radius:12px;padding:22px}
button{background:#5ce7d2;color:#00110f;border:0;border-radius:10px;padding:14px 18px;font-weight:800}
input{width:100%;padding:18px;background:#17202a;color:white;border-radius:10px;margin:16px 0}
</style>
</head>
<body>
<div class="box">
<h1>Cloud Music Offline</h1>
<p>Chọn file MP3, M4A, AAC, WAV hoặc FLAC để gửi vào iPhone.</p>
<form method="post" action="/upload" enctype="multipart/form-data">
<input type="file" name="files" multiple accept=".mp3,.m4a,.aac,.wav,.flac">
<button type="submit">Upload music</button>
</form>
</div>
</body>
</html>
''';
}

String _doneHtml(int imported) {
  return '''
<!doctype html>
<html>
<body style="font-family:-apple-system;background:#080d10;color:white;padding:30px">
<h1>Đã nhận $imported bài hát</h1>
<a style="color:#5ce7d2" href="/">Upload thêm</a>
</body>
</html>
''';
}
