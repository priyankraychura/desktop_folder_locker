import 'dart:convert';
import 'dart:io';

import 'package:desktop_folder_locker/core/storage/json_file_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Object? jsonDecodeFile(String path) =>
    jsonDecode(File(path).readAsStringSync());

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('flk_store_'));
  tearDown(() => dir.delete(recursive: true));

  test('returns null before anything is saved', () async {
    expect(await JsonFileStore(p.join(dir.path, 'a.json')).read(), isNull);
  });

  test('round-trips data and keeps the previous version as backup', () async {
    final path = p.join(dir.path, 'a.json');
    final store = JsonFileStore(path);
    await store.write({'value': 1});
    await store.write({'value': 2});

    expect(await store.read(), {'value': 2});
    expect(File('$path.bak').existsSync(), isTrue);
    expect(File('$path.tmp').existsSync(), isFalse);
  });

  test('the file never goes missing while it is replaced', () async {
    // The Explorer plug-in reads the file as soon as it changes: a moment
    // without it would look like an empty list.
    final path = p.join(dir.path, 'a.json');
    final store = JsonFileStore(path);
    await store.write({'value': 0});
    var done = false;
    var missing = 0;
    final watcher = () async {
      while (!done) {
        if (!File(path).existsSync()) missing++;
        await Future<void>.delayed(Duration.zero);
      }
    }();
    for (var i = 1; i <= 30; i++) {
      await store.write({'value': i});
    }
    done = true;
    await watcher;

    expect(missing, 0);
    expect(await store.read(), {'value': 30});
    expect(jsonDecodeFile('$path.bak'), {'value': 29});
  });

  test('falls back to the backup when the main file is damaged', () async {
    final path = p.join(dir.path, 'a.json');
    final store = JsonFileStore(path);
    await store.write({'value': 1});
    await store.write({'value': 2});
    File(path).writeAsStringSync('{broken');

    expect(await store.read(), {'value': 1});
  });

  test('queued writes never interleave', () async {
    final store = JsonFileStore(p.join(dir.path, 'a.json'));
    await Future.wait([
      for (var i = 0; i < 20; i++) store.write({'value': i}),
    ]);
    expect(await store.read(), {'value': 19});
  });
}
