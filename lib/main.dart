import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CloudMusicApp());
}

class Track {
  Track({
    required this.id,
    required this.title,
    required this.artist,
    required this.path,
    required this.addedAt,
  });

  final String id;
  final String title;
  final String artist;
  final String path;
  final DateTime addedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'path': path,
        'addedAt': addedAt.toIso8601String(),
      };

  factory Track.fromJson(Map<String, dynamic> json) {
    return Track(
      id: json['id'] as String,
      title: json['title'] as String,
      artist: json['artist'] as String? ?? 'Unknown artist',
      path: json['path'] as String,
      addedAt: DateTime.tryParse(json['addedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class EqPreset {
  const EqPreset(this.name, this.values);

  final String name;
  final List<double> values;
}

const _eqPresets = [
  EqPreset('Flat', [0, 0, 0, 0, 0]),
  EqPreset('Bass', [7, 5, 1, 0, 0]),
  EqPreset('Vocal', [-2, 1, 5, 3, -1]),
  EqPreset('Treble', [-1, 0, 1, 5, 7]),
  EqPreset('Warm', [3, 4, 2, -1, -2]),
];

const _eqBandLabels = ['60', '230', '910', '3.6k', '14k'];

class NativeAudioBridge {
  NativeAudioBridge() {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static const _channel = MethodChannel('cloud_music_offline/player');

  Future<void> Function()? onTrackEnded;
  Future<void> Function()? onRemoteNext;
  Future<void> Function()? onRemotePrevious;

  Future<void> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'trackEnded':
        await onTrackEnded?.call();
        break;
      case 'remoteNext':
        await onRemoteNext?.call();
        break;
      case 'remotePrevious':
        await onRemotePrevious?.call();
        break;
    }
  }

  Future<void> setQueue({
    required List<Track> tracks,
    required int index,
    required bool controlsEnabled,
  }) {
    return _channel.invokeMethod('setQueue', {
      'tracks': tracks.map((track) => track.toJson()).toList(),
      'index': index,
      'controlsEnabled': controlsEnabled,
    });
  }

  Future<void> playIndex(int index) {
    return _channel.invokeMethod('playIndex', {'index': index});
  }

  Future<void> play() => _channel.invokeMethod('play');

  Future<void> pause() => _channel.invokeMethod('pause');

  Future<void> seek(double seconds) {
    return _channel.invokeMethod('seek', {'seconds': seconds});
  }

  Future<void> setEq({
    required bool enabled,
    required List<double> bands,
  }) {
    return _channel.invokeMethod('setEQ', {
      'enabled': enabled,
      'bands': bands,
    });
  }

  Future<void> setControlsEnabled(bool enabled) {
    return _channel.invokeMethod('setControlsEnabled', {'enabled': enabled});
  }

  Future<Map<String, dynamic>> getState() async {
    final state = await _channel.invokeMapMethod<String, dynamic>('getState');
    return state ?? <String, dynamic>{};
  }
}

class MusicLibrary extends ChangeNotifier {
  static const _tracksKey = 'tracks';
  static const _airPodsKey = 'airpods_controls_enabled';
  static const _eqEnabledKey = 'eq_enabled';
  static const _eqBandsKey = 'eq_bands';

  final List<Track> _tracks = [];
  bool airPodsControlsEnabled = true;
  bool eqEnabled = true;
  List<double> eqBands = List<double>.from(_eqPresets.first.values);

  List<Track> get tracks => List.unmodifiable(_tracks);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = prefs.getString(_tracksKey);
    if (encoded != null) {
      final raw = jsonDecode(encoded) as List<dynamic>;
      _tracks
        ..clear()
        ..addAll(raw
            .map((item) => Track.fromJson(item as Map<String, dynamic>))
            .where((track) => File(track.path).existsSync()));
    }
    airPodsControlsEnabled = prefs.getBool(_airPodsKey) ?? true;
    eqEnabled = prefs.getBool(_eqEnabledKey) ?? true;
    final bandsJson = prefs.getString(_eqBandsKey);
    if (bandsJson != null) {
      eqBands = (jsonDecode(bandsJson) as List<dynamic>)
          .map((item) => (item as num).toDouble())
          .toList();
    }
    notifyListeners();
  }

  Future<void> importTracks() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['mp3', 'm4a', 'aac', 'wav', 'flac'],
      withData: false,
    );
    if (result == null) return;

    final docs = await getApplicationDocumentsDirectory();
    final musicDir = Directory('${docs.path}/Music');
    if (!musicDir.existsSync()) {
      musicDir.createSync(recursive: true);
    }

    for (final picked in result.files) {
      final sourcePath = picked.path;
      if (sourcePath == null) continue;

      final extension = picked.extension ?? picked.name.split('.').last;
      final cleanName = picked.name
          .replaceAll(RegExp(r'\.[^.]+$'), '')
          .replaceAll(RegExp(r'[^\w .-]'), '_')
          .trim();
      final id = DateTime.now().microsecondsSinceEpoch.toString();
      final target = File('${musicDir.path}/$id.$extension');
      await File(sourcePath).copy(target.path);

      _tracks.insert(
        0,
        Track(
          id: id,
          title: cleanName.isEmpty ? picked.name : cleanName,
          artist: 'Local file',
          path: target.path,
          addedAt: DateTime.now(),
        ),
      );
    }

    await save();
    notifyListeners();
  }

  Future<void> removeTrack(Track track) async {
    _tracks.removeWhere((item) => item.id == track.id);
    final file = File(track.path);
    if (file.existsSync()) {
      await file.delete();
    }
    await save();
    notifyListeners();
  }

  Future<void> setAirPodsControls(bool enabled) async {
    airPodsControlsEnabled = enabled;
    await save();
    notifyListeners();
  }

  Future<void> setEqEnabled(bool enabled) async {
    eqEnabled = enabled;
    await save();
    notifyListeners();
  }

  Future<void> setEqBand(int index, double value) async {
    eqBands[index] = value;
    await save();
    notifyListeners();
  }

  Future<void> applyPreset(EqPreset preset) async {
    eqBands = List<double>.from(preset.values);
    eqEnabled = true;
    await save();
    notifyListeners();
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _tracksKey,
      jsonEncode(_tracks.map((track) => track.toJson()).toList()),
    );
    await prefs.setBool(_airPodsKey, airPodsControlsEnabled);
    await prefs.setBool(_eqEnabledKey, eqEnabled);
    await prefs.setString(_eqBandsKey, jsonEncode(eqBands));
  }
}

class PlayerController extends ChangeNotifier {
  PlayerController(this.library) {
    bridge.onTrackEnded = _handleEnded;
    bridge.onRemoteNext = next;
    bridge.onRemotePrevious = previous;
    _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      refreshState();
    });
  }

  final MusicLibrary library;
  final NativeAudioBridge bridge = NativeAudioBridge();
  Timer? _pollTimer;

  int? currentIndex;
  bool isPlaying = false;
  bool shuffle = false;
  bool repeatOne = false;
  double position = 0;
  double duration = 0;

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
    await bridge.setQueue(
      tracks: library.tracks,
      index: currentIndex!,
      controlsEnabled: library.airPodsControlsEnabled,
    );
    await bridge.setEq(enabled: library.eqEnabled, bands: library.eqBands);
    await bridge.playIndex(currentIndex!);
    isPlaying = true;
    notifyListeners();
  }

  Future<void> togglePlay() async {
    if (currentTrack == null && library.tracks.isNotEmpty) {
      await playTrack(0);
      return;
    }
    if (isPlaying) {
      await bridge.pause();
      isPlaying = false;
    } else {
      await bridge.play();
      isPlaying = true;
    }
    notifyListeners();
  }

  Future<void> seek(double seconds) async {
    position = seconds.clamp(0.0, max(duration, 0.0)).toDouble();
    await bridge.seek(position);
    notifyListeners();
  }

  Future<void> next() async {
    if (library.tracks.isEmpty) return;
    final nextIndex = shuffle
        ? Random().nextInt(library.tracks.length)
        : ((currentIndex ?? -1) + 1) % library.tracks.length;
    await playTrack(nextIndex);
  }

  Future<void> previous() async {
    if (library.tracks.isEmpty) return;
    final previousIndex =
        ((currentIndex ?? 0) - 1 + library.tracks.length) % library.tracks.length;
    await playTrack(previousIndex);
  }

  Future<void> _handleEnded() async {
    if (repeatOne && currentIndex != null) {
      await playTrack(currentIndex!);
    } else {
      await next();
    }
  }

  Future<void> refreshState() async {
    try {
      final state = await bridge.getState();
      isPlaying = state['isPlaying'] as bool? ?? isPlaying;
      position = (state['position'] as num?)?.toDouble() ?? position;
      duration = (state['duration'] as num?)?.toDouble() ?? duration;
      final nativeIndex = state['index'] as int?;
      if (nativeIndex != null && nativeIndex >= 0) {
        currentIndex = nativeIndex;
      }
      notifyListeners();
    } on PlatformException {
      // The native bridge is available on iOS builds. The UI remains usable
      // during desktop editing or tests where the platform side is absent.
    }
  }

  Future<void> syncSettings() async {
    await bridge.setControlsEnabled(library.airPodsControlsEnabled);
    await bridge.setEq(enabled: library.eqEnabled, bands: library.eqBands);
  }

  void toggleShuffle() {
    shuffle = !shuffle;
    notifyListeners();
  }

  void toggleRepeatOne() {
    repeatOne = !repeatOne;
    notifyListeners();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }
}

class CloudMusicApp extends StatefulWidget {
  const CloudMusicApp({super.key});

  @override
  State<CloudMusicApp> createState() => _CloudMusicAppState();
}

class _CloudMusicAppState extends State<CloudMusicApp> {
  final library = MusicLibrary();
  late final PlayerController player = PlayerController(library);
  bool ready = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await library.load();
    await player.syncSettings();
    setState(() => ready = true);
  }

  @override
  Widget build(BuildContext context) {
    return MusicScope(
      library: library,
      player: player,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Cloud Music Offline',
        theme: ThemeData(
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xff12b3a8),
            brightness: Brightness.dark,
          ),
          scaffoldBackgroundColor: const Color(0xff101418),
          useMaterial3: true,
        ),
        home: ready ? const HomeShell() : const LoadingView(),
      ),
    );
  }
}

class MusicScope extends InheritedNotifier<MusicLibrary> {
  const MusicScope({
    required this.library,
    required this.player,
    required super.child,
    super.key,
  }) : super(notifier: library);

  final MusicLibrary library;
  final PlayerController player;

  static MusicScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<MusicScope>();
    assert(scope != null, 'MusicScope not found');
    return scope!;
  }
}

class LoadingView extends StatelessWidget {
  const LoadingView({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
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
    final scope = MusicScope.of(context);
    return AnimatedBuilder(
      animation: Listenable.merge([scope.library, scope.player]),
      builder: (context, _) {
        final pages = [
          const LibraryPage(),
          const PlayerPage(),
          const EqualizerPage(),
          const SettingsPage(),
        ];
        return Scaffold(
          body: SafeArea(child: pages[tab]),
          bottomNavigationBar: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (value) => setState(() => tab = value),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.library_music_outlined),
                selectedIcon: Icon(Icons.library_music),
                label: 'Library',
              ),
              NavigationDestination(
                icon: Icon(Icons.play_circle_outline),
                selectedIcon: Icon(Icons.play_circle),
                label: 'Player',
              ),
              NavigationDestination(
                icon: Icon(Icons.equalizer),
                selectedIcon: Icon(Icons.graphic_eq),
                label: 'EQ',
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: 'Settings',
              ),
            ],
          ),
          bottomSheet: tab == 1 ? null : const MiniPlayer(),
        );
      },
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

  @override
  Widget build(BuildContext context) {
    final scope = MusicScope.of(context);
    final library = scope.library;
    final player = scope.player;
    final tracks = library.tracks
        .where((track) =>
            track.title.toLowerCase().contains(query.toLowerCase()) ||
            track.artist.toLowerCase().contains(query.toLowerCase()))
        .toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 92),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Library',
                  style: TextStyle(fontSize: 32, fontWeight: FontWeight.w800),
                ),
              ),
              FilledButton.icon(
                onPressed: library.importTracks,
                icon: const Icon(Icons.add),
                label: const Text('Import'),
              ),
            ],
          ),
          const SizedBox(height: 18),
          TextField(
            decoration: InputDecoration(
              hintText: 'Search music',
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              filled: true,
            ),
            onChanged: (value) => setState(() => query = value),
          ),
          const SizedBox(height: 20),
          if (library.tracks.isEmpty)
            const Expanded(child: EmptyLibrary())
          else
            Expanded(
              child: ListView.separated(
                itemCount: tracks.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final track = tracks[index];
                  final realIndex =
                      library.tracks.indexWhere((item) => item.id == track.id);
                  final selected = player.currentTrack?.id == track.id;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor: selected
                          ? Theme.of(context).colorScheme.primary
                          : const Color(0xff232a31),
                      child: Icon(
                        selected ? Icons.graphic_eq : Icons.music_note,
                        color: selected ? Colors.black : Colors.white,
                      ),
                    ),
                    title: Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: PopupMenuButton<String>(
                      onSelected: (value) {
                        if (value == 'delete') {
                          library.removeTrack(track);
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'delete',
                          child: Text('Remove offline file'),
                        ),
                      ],
                    ),
                    onTap: () => player.playTrack(realIndex),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class EmptyLibrary extends StatelessWidget {
  const EmptyLibrary({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.folder_open,
            size: 64,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 14),
          const Text(
            'Import music from Files',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          const Text(
            'Google Drive and OneDrive work through the iPhone Files app.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class PlayerPage extends StatelessWidget {
  const PlayerPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = MusicScope.of(context);
    final player = scope.player;
    final track = player.currentTrack;

    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 24),
      child: Column(
        children: [
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Now Playing',
              style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800),
            ),
          ),
          const Spacer(),
          Container(
            width: min(MediaQuery.sizeOf(context).width * 0.72, 320),
            height: min(MediaQuery.sizeOf(context).width * 0.72, 320),
            decoration: BoxDecoration(
              color: const Color(0xff1b242b),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xff33414a)),
            ),
            child: Icon(
              Icons.album,
              size: 118,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(height: 28),
          Text(
            track?.title ?? 'No song selected',
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            track?.artist ?? 'Import a file to start listening',
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 28),
          Slider(
            value: player.duration <= 0
                ? 0.0
                : player.position.clamp(0.0, player.duration).toDouble(),
            min: 0,
            max: max(player.duration, 1),
            onChanged: track == null ? null : (value) => player.seek(value),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_formatDuration(player.position)),
              Text(_formatDuration(player.duration)),
            ],
          ),
          const SizedBox(height: 22),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: 'Shuffle',
                onPressed: player.toggleShuffle,
                icon: Icon(
                  Icons.shuffle,
                  color: player.shuffle
                      ? Theme.of(context).colorScheme.primary
                      : Colors.white,
                ),
              ),
              IconButton(
                tooltip: 'Previous',
                iconSize: 36,
                onPressed: player.previous,
                icon: const Icon(Icons.skip_previous),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  shape: const CircleBorder(),
                  fixedSize: const Size(70, 70),
                ),
                onPressed: player.togglePlay,
                child: Icon(
                  player.isPlaying ? Icons.pause : Icons.play_arrow,
                  size: 38,
                ),
              ),
              IconButton(
                tooltip: 'Next',
                iconSize: 36,
                onPressed: player.next,
                icon: const Icon(Icons.skip_next),
              ),
              IconButton(
                tooltip: 'Repeat one',
                onPressed: player.toggleRepeatOne,
                icon: Icon(
                  Icons.repeat_one,
                  color: player.repeatOne
                      ? Theme.of(context).colorScheme.primary
                      : Colors.white,
                ),
              ),
            ],
          ),
          const Spacer(),
        ],
      ),
    );
  }
}

class EqualizerPage extends StatelessWidget {
  const EqualizerPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = MusicScope.of(context);
    final library = scope.library;
    final player = scope.player;

    Future<void> sync() => player.syncSettings();

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 92),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Equalizer',
                  style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800),
                ),
              ),
              Switch(
                value: library.eqEnabled,
                onChanged: (value) async {
                  await library.setEqEnabled(value);
                  await sync();
                },
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: _eqPresets.map((preset) {
              final active = _sameBands(library.eqBands, preset.values);
              return ChoiceChip(
                label: Text(preset.name),
                selected: active,
                onSelected: (_) async {
                  await library.applyPreset(preset);
                  await sync();
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 26),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: List.generate(_eqBandLabels.length, (index) {
                return Column(
                  children: [
                    Text('${library.eqBands[index].round()} dB'),
                    Expanded(
                      child: RotatedBox(
                        quarterTurns: -1,
                        child: Slider(
                          value: library.eqBands[index],
                          min: -12,
                          max: 12,
                          divisions: 24,
                          onChanged: library.eqEnabled
                              ? (value) async {
                                  await library.setEqBand(index, value);
                                  await sync();
                                }
                              : null,
                        ),
                      ),
                    ),
                    Text(_eqBandLabels[index]),
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

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = MusicScope.of(context);
    final library = scope.library;
    final player = scope.player;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 92),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Settings',
            style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 18),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('AirPods controls'),
            subtitle: const Text('Play, pause, next, and previous from AirPods'),
            value: library.airPodsControlsEnabled,
            onChanged: (value) async {
              await library.setAirPodsControls(value);
              await player.syncSettings();
            },
          ),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.cloud_queue),
            title: const Text('Cloud import'),
            subtitle: const Text('Use Google Drive or OneDrive inside Files'),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.storage),
            title: Text('${library.tracks.length} offline songs'),
            subtitle: const Text('Stored privately inside this app'),
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
    final scope = MusicScope.of(context);
    final player = scope.player;
    final track = player.currentTrack;

    if (track == null) return const SizedBox.shrink();

    return Material(
      color: const Color(0xff171d22),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 74,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                const CircleAvatar(child: Icon(Icons.music_note)),
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
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        _formatDuration(player.position),
                        style: const TextStyle(color: Colors.white60),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Previous',
                  onPressed: player.previous,
                  icon: const Icon(Icons.skip_previous),
                ),
                IconButton(
                  tooltip: player.isPlaying ? 'Pause' : 'Play',
                  onPressed: player.togglePlay,
                  icon: Icon(player.isPlaying ? Icons.pause : Icons.play_arrow),
                ),
                IconButton(
                  tooltip: 'Next',
                  onPressed: player.next,
                  icon: const Icon(Icons.skip_next),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

bool _sameBands(List<double> a, List<double> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if ((a[i] - b[i]).abs() > 0.1) return false;
  }
  return true;
}

String _formatDuration(double seconds) {
  if (!seconds.isFinite || seconds <= 0) return '0:00';
  final duration = Duration(seconds: seconds.round());
  final minutes = duration.inMinutes.remainder(60).toString();
  final secs = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  final hours = duration.inHours;
  if (hours > 0) {
    return '$hours:${minutes.padLeft(2, '0')}:$secs';
  }
  return '$minutes:$secs';
}
