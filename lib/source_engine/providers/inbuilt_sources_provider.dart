import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:shonenx/core/network/http_client.dart';
import 'package:shonenx/shared/providers/storage_provider.dart';
import 'package:shonenx/core/remote_config/providers/remote_config_provider.dart';
import 'package:shonenx/source_engine/dsl_engine/dsl_media_source.dart';
import 'package:shonenx/source_engine/inbuilt_sources/anime/anidb_source.dart';
import 'package:shonenx/source_engine/inbuilt_sources/anime/gojo_source.dart';
import 'package:shonenx/source_engine/inbuilt_sources/anime/anikoto_source.dart';
import 'package:shonenx/source_engine/providers/anime_source.dart';
import 'package:shonenx/source_engine/providers/manga_source.dart';
import 'package:shonenx/source_engine/dsl_engine/dsl_provider_service.dart';

final _inbuiltAnimeListProvider = Provider<List<AnimeSource>>((ref) {
  final client = ref.watch(httpClientProvider);
  final storage = ref.watch(sharedPreferencesProvider);
  return [
    GojoSource(client: client, storage: storage),
    AnidbSource(client: client, storage: storage),
    AnikotoSource(client: client, storage: storage),
  ];
});

final inbuiltAnimeSourcesProvider = Provider<List<AnimeSource>>((ref) {
  final providersAsync = ref.watch(dslProvidersProvider);
  final inbuilt = ref.watch(_inbuiltAnimeListProvider);
  final runtime = ref.watch(dslRuntimeProvider);
  final remoteConfig = ref.watch(remoteConfigServiceProvider);

  final dslSources = providersAsync.maybeWhen(
    data: (map) => map.values
        .where((j) => j['mediaType']?.toString().toUpperCase() == 'ANIME')
        .map((j) => DSLAnimeSource(providerDef: j, runtime: runtime))
        .toList(),
    orElse: () => <AnimeSource>[],
  );

  return [
    ...inbuilt,
    ...dslSources,
  ].where((s) => !remoteConfig.isSourceDisabled(s.sourceInfo.id)).toList();
});

final inbuiltMangaSourcesProvider = Provider<List<MangaSource>>((ref) {
  final providersAsync = ref.watch(dslProvidersProvider);
  final runtime = ref.watch(dslRuntimeProvider);
  final remoteConfig = ref.watch(remoteConfigServiceProvider);

  final dslSources = providersAsync.maybeWhen(
    data: (map) => map.values
        .where((j) => j['mediaType']?.toString().toUpperCase() == 'MANGA')
        .map((j) => DSLMangaSource(providerDef: j, runtime: runtime))
        .toList(),
    orElse: () => <MangaSource>[],
  );

  return dslSources
      .where((s) => !remoteConfig.isSourceDisabled(s.sourceInfo.id))
      .toList();
});
