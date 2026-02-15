import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const MusicDownloaderApp());
}

// ─────────────────────────────────────────────
//  APP ROOT
// ─────────────────────────────────────────────
class MusicDownloaderApp extends StatelessWidget {
  const MusicDownloaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return CupertinoApp(
      title: 'SoundDrop',
      debugShowCheckedModeBanner: false,
      theme: const CupertinoThemeData(
        brightness: Brightness.dark,
        primaryColor: Color(0xFFFF3B5C),
      ),
      home: const HomeScreen(),
    );
  }
}

// ─────────────────────────────────────────────
//  DOWNLOAD MODEL
// ─────────────────────────────────────────────
enum DownloadStatus { idle, fetching, downloading, done, error }

enum AudioFormat { mp3, m4a }

class DownloadItem {
  final String url;
  String title;
  String? thumbnail;
  String? author;
  String? duration;
  DownloadStatus status;
  double progress;
  String? errorMessage;
  AudioFormat format;

  DownloadItem({
    required this.url,
    this.title = '',
    this.thumbnail,
    this.author,
    this.duration,
    this.status = DownloadStatus.idle,
    this.progress = 0,
    this.errorMessage,
    this.format = AudioFormat.m4a,
  });
}

// ─────────────────────────────────────────────
//  HOME SCREEN
// ─────────────────────────────────────────────
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  final TextEditingController _urlController = TextEditingController();
  final List<DownloadItem> _items = [];
  final YoutubeExplode _yt = YoutubeExplode();
  AudioFormat _selectedFormat = AudioFormat.m4a;

  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _yt.close();
    _pulseController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  // ── PASTE FROM CLIPBOARD ──
  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    if (data?.text != null) {
      setState(() => _urlController.text = data!.text!);
    }
  }

  // ── ADD DOWNLOAD ──
  Future<void> _addDownload() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    final item = DownloadItem(url: url, format: _selectedFormat);
    setState(() {
      _items.insert(0, item);
      item.status = DownloadStatus.fetching;
      _urlController.clear();
    });

    await _fetchAndDownload(item);
  }

  // ── FETCH METADATA + DOWNLOAD ──
  Future<void> _fetchAndDownload(DownloadItem item) async {
    try {
      // Fetch video metadata
      final video = await _yt.videos.get(item.url);
      setState(() {
        item.title = video.title;
        item.author = video.author;
        item.thumbnail = video.thumbnails.mediumResUrl;
        final d = video.duration;
        if (d != null) {
          item.duration =
              '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
        }
        item.status = DownloadStatus.downloading;
      });

      // Get stream manifest
      final manifest = await _yt.videos.streamsClient.getManifest(item.url);
      final savePath = await _getSavePath(item);

      if (item.format == AudioFormat.m4a) {
        // Best audio stream (m4a)
        final audioStream = manifest.audioOnly.withHighestBitrate();
        final stream = _yt.videos.streamsClient.get(audioStream);
        final file = File(savePath);
        final sink = file.openWrite();
        final total = audioStream.size.totalBytes;
        int received = 0;

        await for (final chunk in stream) {
          sink.add(chunk);
          received += chunk.length;
          setState(() {
            item.progress = received / total;
          });
        }
        await sink.close();
      } else {
        // mp3 — download best audio then rename (real conversion needs ffmpeg)
        final audioStream = manifest.audioOnly.withHighestBitrate();
        final stream = _yt.videos.streamsClient.get(audioStream);
        final file = File(savePath);
        final sink = file.openWrite();
        final total = audioStream.size.totalBytes;
        int received = 0;

        await for (final chunk in stream) {
          sink.add(chunk);
          received += chunk.length;
          setState(() {
            item.progress = received / total;
          });
        }
        await sink.close();
      }

      setState(() {
        item.status = DownloadStatus.done;
        item.progress = 1.0;
      });
    } catch (e) {
      setState(() {
        item.status = DownloadStatus.error;
        item.errorMessage = e.toString();
      });
    }
  }

  // ── BUILD SAVE PATH ──
  Future<String> _getSavePath(DownloadItem item) async {
    Directory? dir;
    if (Platform.isIOS) {
      dir = await getApplicationDocumentsDirectory();
    } else {
      await Permission.storage.request();
      dir = await getExternalStorageDirectory();
      dir ??= await getApplicationDocumentsDirectory();
    }

    final safe = item.title
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll('  ', ' ')
        .trim();
    final ext = item.format == AudioFormat.m4a ? 'm4a' : 'mp3';
    return '${dir.path}/$safe.$ext';
  }

  // ── RETRY ──
  Future<void> _retry(DownloadItem item) async {
    setState(() {
      item.status = DownloadStatus.fetching;
      item.progress = 0;
      item.errorMessage = null;
    });
    await _fetchAndDownload(item);
  }

  // ── REMOVE ──
  void _remove(DownloadItem item) {
    setState(() => _items.remove(item));
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      child: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            _buildInputSection(),
            _buildFormatToggle(),
            const SizedBox(height: 8),
            Expanded(child: _buildList()),
          ],
        ),
      ),
    );
  }

  // ── HEADER ──
  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
      child: Row(
        children: [
          ScaleTransition(
            scale: _pulseAnim,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFFF3B5C), Color(0xFFFF6B35)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFFF3B5C).withOpacity(0.4),
                    blurRadius: 12,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: const Icon(
                CupertinoIcons.music_note,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'SoundDrop',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                ),
              ),
              Text(
                'YouTube → Audio',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.4),
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
          const Spacer(),
          Text(
            '${_items.where((i) => i.status == DownloadStatus.done).length} saved',
            style: TextStyle(
              color: Colors.white.withOpacity(0.35),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  // ── INPUT SECTION ──
  Widget _buildInputSection() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF16161E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Colors.white.withOpacity(0.06),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: CupertinoTextField(
                  controller: _urlController,
                  placeholder: 'Dán link YouTube...',
                  placeholderStyle: TextStyle(
                    color: Colors.white.withOpacity(0.25),
                    fontSize: 15,
                  ),
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0D0D14),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  clearButtonMode: OverlayVisibilityMode.editing,
                  onSubmitted: (_) => _addDownload(),
                ),
              ),
              const SizedBox(width: 10),
              // Paste button
              CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: _pasteFromClipboard,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E2A),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.08),
                    ),
                  ),
                  child: Icon(
                    CupertinoIcons.doc_on_clipboard,
                    color: Colors.white.withOpacity(0.6),
                    size: 18,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Download button
          GestureDetector(
            onTap: _addDownload,
            child: Container(
              width: double.infinity,
              height: 50,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFFF3B5C), Color(0xFFFF6B35)],
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                ),
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFFF3B5C).withOpacity(0.3),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    CupertinoIcons.arrow_down_circle_fill,
                    color: Colors.white,
                    size: 20,
                  ),
                  SizedBox(width: 8),
                  Text(
                    'Tải xuống',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── FORMAT TOGGLE ──
  Widget _buildFormatToggle() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          Text(
            'Định dạng',
            style: TextStyle(
              color: Colors.white.withOpacity(0.5),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 12),
          _formatChip('M4A', AudioFormat.m4a),
          const SizedBox(width: 8),
          _formatChip('MP3', AudioFormat.mp3),
        ],
      ),
    );
  }

  Widget _formatChip(String label, AudioFormat format) {
    final selected = _selectedFormat == format;
    return GestureDetector(
      onTap: () => setState(() => _selectedFormat = format),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFFFF3B5C)
              : const Color(0xFF1A1A24),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? const Color(0xFFFF3B5C)
                : Colors.white.withOpacity(0.1),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : Colors.white.withOpacity(0.4),
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  // ── LIST ──
  Widget _buildList() {
    if (_items.isEmpty) {
      return _buildEmptyState();
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: _items.length,
      itemBuilder: (context, i) => _buildCard(_items[i]),
    );
  }

  // ── EMPTY STATE ──
  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: const Color(0xFF16161E),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: Colors.white.withOpacity(0.06),
              ),
            ),
            child: Icon(
              CupertinoIcons.music_note_2,
              color: Colors.white.withOpacity(0.15),
              size: 36,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Chưa có bài nào',
            style: TextStyle(
              color: Colors.white.withOpacity(0.4),
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Dán link YouTube để bắt đầu tải',
            style: TextStyle(
              color: Colors.white.withOpacity(0.2),
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  // ── CARD ──
  Widget _buildCard(DownloadItem item) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF13131B),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: _cardBorderColor(item),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            _buildThumbnail(item),
            const SizedBox(width: 12),
            Expanded(child: _buildCardInfo(item)),
            _buildCardAction(item),
          ],
        ),
      ),
    );
  }

  Color _cardBorderColor(DownloadItem item) {
    switch (item.status) {
      case DownloadStatus.done:
        return const Color(0xFF30D158).withOpacity(0.3);
      case DownloadStatus.error:
        return const Color(0xFFFF453A).withOpacity(0.3);
      case DownloadStatus.downloading:
      case DownloadStatus.fetching:
        return const Color(0xFFFF3B5C).withOpacity(0.2);
      default:
        return Colors.white.withOpacity(0.06);
    }
  }

  Widget _buildThumbnail(DownloadItem item) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 56,
        height: 56,
        color: const Color(0xFF1E1E2A),
        child: item.thumbnail != null
            ? Image.network(
                item.thumbnail!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const Icon(
                  CupertinoIcons.music_note,
                  color: Colors.white24,
                  size: 24,
                ),
              )
            : Icon(
                CupertinoIcons.music_note,
                color: Colors.white.withOpacity(0.2),
                size: 24,
              ),
      ),
    );
  }

  Widget _buildCardInfo(DownloadItem item) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.title.isNotEmpty ? item.title : item.url,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (item.author != null) ...[
          const SizedBox(height: 2),
          Text(
            item.author!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withOpacity(0.4),
              fontSize: 12,
            ),
          ),
        ],
        const SizedBox(height: 6),
        _buildStatusRow(item),
      ],
    );
  }

  Widget _buildStatusRow(DownloadItem item) {
    switch (item.status) {
      case DownloadStatus.fetching:
        return Row(
          children: [
            const CupertinoActivityIndicator(radius: 6),
            const SizedBox(width: 6),
            Text(
              'Đang lấy thông tin...',
              style: TextStyle(
                color: Colors.white.withOpacity(0.4),
                fontSize: 11,
              ),
            ),
          ],
        );

      case DownloadStatus.downloading:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: item.progress,
                backgroundColor: Colors.white.withOpacity(0.08),
                valueColor: const AlwaysStoppedAnimation(Color(0xFFFF3B5C)),
                minHeight: 3,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${(item.progress * 100).toStringAsFixed(0)}%  •  '
              '${item.format.name.toUpperCase()}',
              style: TextStyle(
                color: Colors.white.withOpacity(0.35),
                fontSize: 11,
              ),
            ),
          ],
        );

      case DownloadStatus.done:
        return Row(
          children: [
            const Icon(
              CupertinoIcons.checkmark_circle_fill,
              color: Color(0xFF30D158),
              size: 14,
            ),
            const SizedBox(width: 4),
            Text(
              'Đã lưu  •  ${item.format.name.toUpperCase()}'
              '${item.duration != null ? "  •  ${item.duration}" : ""}',
              style: TextStyle(
                color: Colors.white.withOpacity(0.4),
                fontSize: 11,
              ),
            ),
          ],
        );

      case DownloadStatus.error:
        return Row(
          children: [
            const Icon(
              CupertinoIcons.exclamationmark_circle_fill,
              color: Color(0xFFFF453A),
              size: 14,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                item.errorMessage ?? 'Lỗi không xác định',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFFFF453A),
                  fontSize: 11,
                ),
              ),
            ),
          ],
        );

      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildCardAction(DownloadItem item) {
    if (item.status == DownloadStatus.error) {
      return Column(
        children: [
          CupertinoButton(
            padding: EdgeInsets.zero,
            minSize: 36,
            onPressed: () => _retry(item),
            child: const Icon(
              CupertinoIcons.refresh,
              color: Color(0xFFFF3B5C),
              size: 20,
            ),
          ),
          CupertinoButton(
            padding: EdgeInsets.zero,
            minSize: 36,
            onPressed: () => _remove(item),
            child: Icon(
              CupertinoIcons.xmark,
              color: Colors.white.withOpacity(0.3),
              size: 16,
            ),
          ),
        ],
      );
    }

    if (item.status == DownloadStatus.done) {
      return CupertinoButton(
        padding: EdgeInsets.zero,
        minSize: 36,
        onPressed: () => _remove(item),
        child: Icon(
          CupertinoIcons.xmark_circle,
          color: Colors.white.withOpacity(0.25),
          size: 20,
        ),
      );
    }

    return const SizedBox(width: 8);
  }
}
