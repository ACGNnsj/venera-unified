import 'dart:isolate';

import 'package:uuid/uuid.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/features/local_comics/local.dart';
import 'package:venera_unified/foundation/file_type.dart';
import 'package:venera_unified/foundation/file_interaction.dart';
import 'package:venera_unified/foundation/zip_writer.dart';

import 'comic_export_service.dart';

class EpubData {
  final String title;

  final String author;

  final File cover;

  final Map<String, List<File>> chapters;

  const EpubData({
    required this.title,
    required this.author,
    required this.cover,
    required this.chapters,
  });
}

Future<File> createEpubComic(
  EpubData data,
  String cacheDir,
  String outFilePath,
) async {
  // A private temp directory keeps concurrent exports from deleting each
  // other's staging files.
  final workingDir = await Directory(cacheDir).createTemp('epub-');
  try {
    // mimetype
    await workingDir.joinFile('mimetype').writeAsString('application/epub+zip');

    // META-INF
    await Directory(FilePath.join(workingDir.path, 'META-INF')).create();
    await File(
      FilePath.join(workingDir.path, 'META-INF', 'container.xml'),
    ).writeAsString('''
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
  ''');

    await Directory(FilePath.join(workingDir.path, 'OEBPS')).create();

    // copy images, create html files
    final imageDir = Directory(
      FilePath.join(workingDir.path, 'OEBPS', 'images'),
    );
    await imageDir.create();
    final coverExt = data.cover.extension;
    final coverMime = FileType.fromExtension(coverExt).mime;
    await imageDir
        .joinFile('cover.$coverExt')
        .writeAsBytes(await data.cover.readAsBytes());
    int imgIndex = 0;
    int chapterIndex = 0;
    var manifestStrBuilder = StringBuffer();
    manifestStrBuilder.writeln(
      '        <item id="cover_image" href="OEBPS/images/cover.$coverExt" media-type="$coverMime"/>',
    );
    manifestStrBuilder.writeln(
      '        <item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
    );
    for (final chapter in data.chapters.keys) {
      var images = <String>[];
      for (final image in data.chapters[chapter]!) {
        final ext = image.extension;
        await imageDir
            .joinFile('img$imgIndex.$ext')
            .writeAsBytes(await image.readAsBytes());
        images.add('images/img$imgIndex.$ext');
        var mime = FileType.fromExtension(ext).mime;
        manifestStrBuilder.writeln(
          '        <item id="img$imgIndex" href="OEBPS/images/img$imgIndex.$ext" media-type="$mime"/>',
        );
        imgIndex++;
      }
      var html = File(
        FilePath.join(workingDir.path, 'OEBPS', '$chapterIndex.html'),
      );
      await html.writeAsString('''
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" 
    "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
    <title>${_escapeEpubXml(chapter)}</title>
    <style type="text/css">
        img { 
            max-width: 100%;
            height: auto;
        }
        body {
            margin: 0;
            padding: 0;
        }
    </style>
</head>
<body>
    <h1>${_escapeEpubXml(chapter)}</h1>
    <div>
${images.map((e) => '        <img src="$e" alt="$e"/>').join('\n')}
    </div>
</body>
</html>
    ''');
      manifestStrBuilder.writeln(
        '        <item id="chapter$chapterIndex" href="OEBPS/$chapterIndex.html" media-type="application/xhtml+xml"/>',
      );
      chapterIndex++;
    }

    // content.opf
    final contentOpf = File(FilePath.join(workingDir.path, 'content.opf'));
    final uuid = const Uuid().v4();
    var spineStrBuilder = StringBuffer();
    for (var i = 0; i < chapterIndex; i++) {
      var idRef = 'idref="chapter$i"';
      spineStrBuilder.writeln('        <itemref $idRef/>');
    }
    await contentOpf.writeAsString('''
<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0" 
    xmlns="http://www.idpf.org/2007/opf"
    xmlns:dc="http://purl.org/dc/elements/1.1/">
    <metadata>
        <dc:title>${_escapeEpubXml(data.title)}</dc:title>
        <dc:creator>${_escapeEpubXml(data.author)}</dc:creator>
        <dc:identifier id="book_id">urn:uuid:$uuid</dc:identifier>
        <meta name="cover" content="cover_image"/>
    </metadata>
    <manifest>
${manifestStrBuilder.toString()}       
    </manifest>
    <spine toc="toc">
${spineStrBuilder.toString()}
    </spine>
</package>
  ''');

    // toc.ncx
    final tocNcx = File(FilePath.join(workingDir.path, 'toc.ncx'));
    var navMapStrBuilder = StringBuffer();
    var playOrder = 2;
    final chapterNames = data.chapters.keys.toList();
    for (var i = 0; i < chapterIndex; i++) {
      navMapStrBuilder.writeln(
        '        <navPoint id="chapter$i" playOrder="$playOrder">',
      );
      navMapStrBuilder.writeln(
        '            <navLabel><text>${_escapeEpubXml(chapterNames[i])}</text></navLabel>',
      );
      navMapStrBuilder.writeln('            <content src="OEBPS/$i.html"/>');
      navMapStrBuilder.writeln('        </navPoint>');
      playOrder++;
    }

    await tocNcx.writeAsString('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx" version="2005-1">
    <head>
        <meta name="dtb:uid" content="urn:uuid:$uuid"/>
        <meta name="dtb:depth" content="1"/>
        <meta name="dtb:totalPageCount" content="0"/>
        <meta name="dtb:maxPageNumber" content="0"/>
    </head>
    <docTitle>
        <text>${_escapeEpubXml(data.title)}</text>
    </docTitle>
    <navMap>
${navMapStrBuilder.toString()}
    </navMap>
</ncx>
  ''');

    await writeZipFromDirectory(workingDir.path, outFilePath);

    return File(outFilePath);
  } finally {
    await workingDir.delete(recursive: true);
  }
}

String _escapeEpubXml(String value) {
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

Future<File> createEpubWithLocalComic(
  LocalComic comic,
  String outFilePath,
) async {
  requireCompleteComicForExport(comic);
  // Transfer paths only: File objects own native handles and must not cross
  // the isolate boundary. Fresh handles are acquired inside the worker.
  var chapters = <String, List<String>>{};
  if (comic.chapters == null) {
    chapters[comic.title] = await LocalManager().getImages(
      comic.id,
      comic.comicType,
      0,
    );
  } else {
    for (var chapter in comic.downloadedChapters) {
      chapters[comic.chapters![chapter]!] = await LocalManager().getImages(
        comic.id,
        comic.comicType,
        chapter,
      );
    }
  }
  final title = comic.title;
  final author = comic.subtitle;
  final coverPath = comic.coverFile.path;
  final cacheDir = App.cachePath;

  return Isolate.run(
    () => overrideIO(() async {
      final data = EpubData(
        title: title,
        author: author,
        cover: _imageFileFromUri(coverPath),
        chapters: chapters.map(
          (name, paths) =>
              MapEntry(name, paths.map(_imageFileFromUri).toList()),
        ),
      );
      return createEpubComic(data, cacheDir, outFilePath);
    }),
  );
}

/// Total on-disk size of a local comic, used for export size stats.
Future<int> localComicDirectorySize(LocalComic comic) async {
  var bytes = 0;
  await for (final entity in Directory(
    comic.baseDir,
  ).list(recursive: true, followLinks: false)) {
    if (entity is File) bytes += await entity.length();
  }
  return bytes;
}

File _imageFileFromUri(String uri) => File(uri.replaceFirst('file://', ''));
