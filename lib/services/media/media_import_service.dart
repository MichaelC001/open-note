// lib/services/media/media_import_service.dart
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'media_tool_service.dart';
import 'transcript_formatter.dart';
import 'transcript_parser.dart';
import 'whisper_model_service.dart';
import 'whisper_runner.dart';
import 'wav_duration.dart';

enum MediaImportPhase { acquiring, extractingAudio, transcribing, formatting }

class MediaImportException implements Exception {
  static const String cancelledMessage = '已取消';

  final String message;
  final String? detail;

  const MediaImportException(this.message, [this.detail]);

  @override
  String toString() => detail == null ? message : '$message\n$detail';
}

class MediaImportRequest {
  final String? url;
  final File? localFile;
  final WhisperModelTier tier;
  final String language;
  final bool deleteSourceAfter;

  const MediaImportRequest({
    this.url,
    this.localFile,
    required this.tier,
    this.language = 'auto',
    this.deleteSourceAfter = true,
  });
}

class MediaImportResult {
  final String markdown;
  final String title;
  final String? sourceUrl;
  final bool formattedByAI;

  const MediaImportResult({
    required this.markdown,
    required this.title,
    this.sourceUrl,
    required this.formattedByAI,
  });
}

class MediaImportService {
  final MediaToolService toolService;
  final WhisperModelService modelService;
  final WhisperRunner whisperRunner;
  final TranscriptFormatter? formatter;
  final Future<String> Function() resolveBaseDir;

  final List<Process> _active = [];
  bool _cancelled = false;

  MediaImportService({
    MediaToolService? toolService,
    WhisperModelService? modelService,
    WhisperRunner? whisperRunner,
    this.formatter,
    Future<String> Function()? resolveBaseDir,
  }) : toolService = toolService ?? MediaToolService(),
       modelService = modelService ?? WhisperModelService(),
       whisperRunner = whisperRunner ?? WhisperRunner(),
       resolveBaseDir = resolveBaseDir ?? _defaultBaseDir;

  static Future<String> _defaultBaseDir() async =>
      (await getApplicationSupportDirectory()).path;

  void cancel() {
    _cancelled = true;
    for (final p in List<Process>.from(_active)) {
      p.kill();
    }
    _active.clear();
  }

  void _ensureAlive() {
    if (_cancelled) {
      throw const MediaImportException(MediaImportException.cancelledMessage);
    }
  }

  static String deriveTitleFromMedia(String mediaPath) {
    final name = mediaPath.split(Platform.pathSeparator).last;
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final t = base.trim();
    return t.isEmpty ? '视频笔记' : t;
  }

  static int? parseFfmpegDurationSec(String stderr) {
    final m = RegExp(r'Duration:\s*(\d+):(\d+):(\d+)\.\d+').firstMatch(stderr);
    if (m == null) return null;
    return int.parse(m.group(1)!) * 3600 +
        int.parse(m.group(2)!) * 60 +
        int.parse(m.group(3)!);
  }

  static double? parseFfmpegTimeSec(String chunk) {
    double? latest;
    final re = RegExp(r'time=(\d+):(\d+):(\d+)\.(\d+)');
    for (final m in re.allMatches(chunk)) {
      latest =
          int.parse(m.group(1)!) * 3600 +
          int.parse(m.group(2)!) * 60 +
          int.parse(m.group(3)!) +
          int.parse(m.group(4)!) / 100.0;
    }
    return latest;
  }

  Future<MediaImportResult> run(
    MediaImportRequest req, {
    void Function(MediaImportPhase phase, double? progress)? onProgress,
  }) async {
    final taskId = const Uuid().v4();
    final tmpRoot = Directory(
      '${await resolveBaseDir()}/media_import_tmp/$taskId',
    );
    await tmpRoot.create(recursive: true);
    try {
      onProgress?.call(MediaImportPhase.acquiring, null);
      final mediaFile = await _acquire(req, tmpRoot, (p) {
        _ensureAlive();
        onProgress?.call(MediaImportPhase.acquiring, p);
      });
      _ensureAlive();

      onProgress?.call(MediaImportPhase.extractingAudio, null);
      final wav = await _toWav(mediaFile, tmpRoot, (p) {
        _ensureAlive();
        onProgress?.call(MediaImportPhase.extractingAudio, p);
      });
      _ensureAlive();

      onProgress?.call(MediaImportPhase.transcribing, 0.0);
      final model = await modelService.localModelFile(req.tier);
      if (model == null) {
        throw const MediaImportException('所选模型尚未下载，请先在环境检查中下载');
      }
      final cli = await toolService.check(MediaToolKind.whisperCli);
      if (!cli.ready || cli.path == null) {
        throw const MediaImportException('whisper.cpp 未就绪，请先完成环境检查');
      }
      final totalMs = estimateWavDurationMs(await wav.length());
      final transcript = await whisperRunner.transcribe(
        whisperCliPath: cli.path!,
        model: model,
        wav: wav,
        language: req.language,
        totalDurationMs: totalMs,
        onProgress: (p) {
          _ensureAlive();
          onProgress?.call(MediaImportPhase.transcribing, p);
        },
        onStarted: _active.add,
      );
      _ensureAlive();

      onProgress?.call(MediaImportPhase.formatting, null);
      String markdown;
      var ai = false;
      try {
        if (formatter == null) {
          throw const MediaImportException('AI 未配置');
        }
        markdown = await formatter!.format(transcript);
        ai = true;
      } catch (_) {
        markdown = _fallbackMarkdown(transcript);
      }
      _ensureAlive();

      var title = deriveTitleFromMedia(mediaFile.path);
      if (ai) {
        final suggested = await formatter!.suggestTitle(markdown);
        if (suggested != null && suggested.isNotEmpty) title = suggested;
      }

      if (!req.deleteSourceAfter) {
        final keepRoot = Directory(
          '${await resolveBaseDir()}/media_import_media',
        );
        await keepRoot.create(recursive: true);
        final dest = File(
          '${keepRoot.path}/${DateTime.now().millisecondsSinceEpoch}_${mediaFile.uri.pathSegments.last}',
        );
        try {
          await mediaFile.copy(dest.path);
        } catch (_) {}
      }

      return MediaImportResult(
        markdown: markdown,
        title: title,
        sourceUrl: req.url,
        formattedByAI: ai,
      );
    } finally {
      for (final p in List<Process>.from(_active)) {
        p.kill();
      }
      _active.clear();
      try {
        await tmpRoot.delete(recursive: true);
      } catch (_) {}
    }
  }

  static String _fallbackMarkdown(Transcript t) =>
      TranscriptFormatter(_neverCall).fallbackMarkdown(t);

  static Future<String> _neverCall(String p) async =>
      throw UnsupportedError('fallback only');

  Future<File> _acquire(
    MediaImportRequest req,
    Directory workDir,
    void Function(double) onProgress,
  ) async {
    if (req.localFile != null) return req.localFile!;
    final url = req.url;
    if (url == null || url.isEmpty) {
      throw const MediaImportException('缺少导入来源');
    }
    final yt = await toolService.check(MediaToolKind.ytDlp);
    if (!yt.ready || yt.path == null) {
      throw const MediaImportException('yt-dlp 未安装，请先在环境检查中安装');
    }
    final process = await Process.start(yt.path!, [
      '--no-playlist',
      '--newline',
      '-f',
      'ba/b',
      '-o',
      '%(title).80s [%(id)s].%(ext)s',
      '--print',
      'after_move:filepath',
      url,
    ], workingDirectory: workDir.path);
    _active.add(process);
    final sbErr = StringBuffer();
    String? lastPlainLine;
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.trim().isEmpty) return;
          final pct = RegExp(r'(\d+(?:\.\d+)?)%').firstMatch(line);
          if (pct != null && line.contains('[download]')) {
            onProgress(double.parse(pct.group(1)!) / 100);
            return;
          }
          if (!line.startsWith('[')) lastPlainLine = line.trim();
        });
    process.stderr.transform(utf8.decoder).listen(sbErr.write);
    final code = await process.exitCode;
    _active.remove(process);
    _ensureAlive();
    if (code != 0 || lastPlainLine == null) {
      throw MediaImportException('URL 媒体下载失败，站点可能不支持或网络异常', _tail(sbErr));
    }
    return File(lastPlainLine!);
  }

  Future<File> _toWav(
    File input,
    Directory workDir,
    void Function(double) onProgress,
  ) async {
    final ff = await toolService.check(MediaToolKind.ffmpeg);
    if (!ff.ready || ff.path == null) {
      throw const MediaImportException('ffmpeg 未安装，请先在环境检查中安装');
    }
    final wavPath = '${workDir.path}/audio.wav';
    final args = [
      '-y',
      '-i',
      input.path,
      '-vn',
      '-ar',
      '16000',
      '-ac',
      '1',
      '-c:a',
      'pcm_s16le',
      wavPath,
    ];
    Process process;
    try {
      process = await Process.start(ff.path!, args);
    } on ProcessException {
      // ffmpeg 无法启动（如测试环境）：输入已是 WAV 时直接透传，否则报错
      if (input.path.toLowerCase().endsWith('.wav')) return input;
      throw const MediaImportException('音频提取失败：无法启动 ffmpeg');
    }
    _active.add(process);
    final sbErr = StringBuffer();
    int? totalSec;
    process.stderr.transform(utf8.decoder).listen((chunk) {
      sbErr.write(chunk);
      totalSec ??= parseFfmpegDurationSec(sbErr.toString());
      final t = parseFfmpegTimeSec(chunk);
      if (t != null && totalSec != null && totalSec! > 0) {
        onProgress((t / totalSec!).clamp(0.0, 1.0));
      }
    });
    final code = await process.exitCode;
    _active.remove(process);
    _ensureAlive();
    if (code != 0) {
      throw MediaImportException('音频提取失败', _tail(sbErr));
    }
    final wav = File(wavPath);
    if (!await wav.exists()) {
      throw const MediaImportException('音频提取失败：未生成 WAV');
    }
    return wav;
  }

  static String _tail(StringBuffer sb) {
    final s = sb.toString();
    return s.length > 2000 ? s.substring(s.length - 2000) : s;
  }
}
