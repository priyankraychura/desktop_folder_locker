import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/core_providers.dart';
import '../../../core/storage/json_file_store.dart';
import '../domain/app_settings.dart';

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepository(
    JsonFileStore(ref.watch(appPathsProvider).settingsFile),
  ),
);

/// Persists [AppSettings] in `settings.json`.
class SettingsRepository {
  SettingsRepository(this._store);

  final JsonFileStore _store;

  Future<AppSettings> load() async {
    final json = await _store.read();
    return json == null ? const AppSettings() : AppSettings.fromJson(json);
  }

  Future<void> save(AppSettings settings) => _store.write(settings.toJson());
}
