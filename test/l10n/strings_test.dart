// test/l10n/strings_test.dart
// ② 「从URL创建」→「网页剪报」改名、③ 新建菜单 Tooltip 键、④ 剪贴板条新键
import 'package:flutter_test/flutter_test.dart';
import 'package:open_note/l10n/strings.g.dart';

void main() {
  test('home_createFromUrl / dialog_createFromUrl 四语言改为「网页剪报」', () async {
    final zh = await AppLocale.zh.build();
    expect(zh.home_createFromUrl, '网页剪报');
    expect(zh.dialog_createFromUrl, '网页剪报');

    final zhTw = await AppLocale.zhTw.build();
    expect(zhTw.home_createFromUrl, '網頁剪報');
    expect(zhTw.dialog_createFromUrl, '網頁剪報');

    final en = await AppLocale.en.build();
    expect(en.home_createFromUrl, 'Web clip');
    expect(en.dialog_createFromUrl, 'Web clip');

    final ru = await AppLocale.ru.build();
    expect(ru.home_createFromUrl, 'Веб-клип');
    expect(ru.dialog_createFromUrl, 'Веб-клип');
  });

  test('新建菜单 Tooltip 四键四语言', () async {
    final zh = await AppLocale.zh.build();
    expect(zh.home_hintNew, '新建一篇空白笔记，从零开始书写');
    expect(zh.home_hintWebclip, '粘贴网页链接，提取正文保存为笔记');
    expect(zh.home_hintFile, '导入本地文件内容生成笔记');
    expect(zh.home_hintVideo, '从视频或音频链接、本地文件生成转写笔记');

    final zhTw = await AppLocale.zhTw.build();
    expect(zhTw.home_hintNew, '新建一篇空白筆記，從零開始書寫');
    expect(zhTw.home_hintWebclip, '貼上網頁連結，擷取正文儲存為筆記');
    expect(zhTw.home_hintFile, '匯入本機檔案內容產生筆記');
    expect(zhTw.home_hintVideo, '從影片或音訊連結、本機檔案產生轉寫筆記');

    final en = await AppLocale.en.build();
    expect(en.home_hintNew, 'Create a new blank note from scratch');
    expect(en.home_hintWebclip, 'Paste a web link to extract its content into a note');
    expect(en.home_hintFile, 'Import a local file to create a note');
    expect(en.home_hintVideo, 'Transcribe video or audio from a link or local file into notes');

    final ru = await AppLocale.ru.build();
    expect(ru.home_hintNew, 'Создать пустую заметку с нуля');
    expect(ru.home_hintWebclip, 'Вставьте ссылку, чтобы извлечь текст в заметку');
    expect(ru.home_hintFile, 'Импорт локального файла в заметку');
    expect(ru.home_hintVideo, 'Расшифровка видео или аудио по ссылке или файлу');
  });

  test('剪贴板条新键 home_clipWebclip / home_clipMedia 四语言', () async {
    final zh = await AppLocale.zh.build();
    expect(zh.home_clipWebclip, '网页剪报');
    expect(zh.home_clipMedia, '从音视频中创建');

    final zhTw = await AppLocale.zhTw.build();
    expect(zhTw.home_clipWebclip, '網頁剪報');
    expect(zhTw.home_clipMedia, '從音訊視訊中建立');

    final en = await AppLocale.en.build();
    expect(en.home_clipWebclip, 'Web clip');
    expect(en.home_clipMedia, 'Create from audio/video');

    final ru = await AppLocale.ru.build();
    expect(ru.home_clipWebclip, 'Веб-клип');
    expect(ru.home_clipMedia, 'Создать из аудио/видео');
  });
}
