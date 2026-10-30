import 'preferences.dart';

abstract final class AppPreferences {
  static const language = ChoicePreference('language', 'system', [
    'system',
    'zh-CN',
    'zh-TW',
    'en-US',
  ]);
  static const checkUpdateOnStart = BoolPreference('checkUpdateOnStart', false);
  // The editor range is not a storage limit: older settings may retain history
  // longer. 100 million days fit DateTime/Duration without integer overflow.
  static const historyRetentionDays = RoundedIntPreference(
    'historyRetentionDays',
    0,
    min: 0,
    max: 100000000,
  );
  static const historyRetentionEditorMax = 182.0;
  static const historyRetentionEditorStep = 7.0;
  // Largest whole MiB value whose byte count fits a signed 64-bit integer.
  static const maxCacheSizeMb = 8796093022207;
  static const cacheSize = NumericPreference(
    'cacheSize',
    2048,
    min: 0,
    max: 8796093022207.0,
    step: 1,
    integer: true,
  );
  // Days of image-cache age before eviction. Zero keeps entries until the
  // size limit evicts them. Only the service's fixed allowlist is offered.
  static const cacheRetentionDays = RoundedIntPreference(
    'cacheRetentionDays',
    7,
    min: 0,
    max: 30,
  );
  static const authorizationRequired = BoolPreference(
    'authorizationRequired',
    false,
  );
  static const reverseChapterOrder = BoolPreference(
    'reverseChapterOrder',
    false,
  );
  static const minimizeToTray = BoolPreference('minimizeToTray', false);
  static const all = <Preference<Object>>[
    language,
    checkUpdateOnStart,
    historyRetentionDays,
    cacheSize,
    cacheRetentionDays,
    authorizationRequired,
    reverseChapterOrder,
    minimizeToTray,
  ];
}

abstract final class NetworkPreferences {
  static const proxy = StringPreference('proxy', 'system');
  static const enableDnsOverrides = BoolPreference('enableDnsOverrides', false);
  static const dnsOverrides = StringMapPreference('dnsOverrides');
  static const sni = BoolPreference('sni', true);
  static const ignoreBadCertificate = BoolPreference(
    'ignoreBadCertificate',
    false,
  );
  static const downloadThreads = NumericPreference(
    'downloadThreads',
    5,
    min: 1,
    max: 16,
    step: 1,
    integer: true,
  );
  static const skipUnavailableDownloadImages = BoolPreference(
    'skipUnavailableDownloadImages',
    false,
  );
  static const all = <Preference<Object>>[
    proxy,
    enableDnsOverrides,
    dnsOverrides,
    sni,
    ignoreBadCertificate,
    downloadThreads,
    skipUnavailableDownloadImages,
  ];
}

abstract final class AppearancePreferences {
  static const themeMode = ChoicePreference('theme_mode', 'system', [
    'system',
    'light',
    'dark',
  ]);
  // Yellow and cyan are supported by existing saved configurations even though
  // the current selector does not offer them.
  static const color = ChoicePreference('color', 'system', [
    'system',
    'red',
    'pink',
    'purple',
    'green',
    'orange',
    'blue',
    'yellow',
    'cyan',
  ]);
  // 评论正文的字号。只影响评论卡片里的文字，正文与阅读器等其它排版各有
  // 自己的设置，彼此不联动。
  static const commentFontSize = NumericPreference(
    'commentFontSize',
    14,
    min: 12,
    max: 24,
    step: 1,
    integer: true,
  );
  // 夜览：整屏压低蓝通道，夜里看白色页面不刺眼。默认关闭。
  static const nightMode = BoolPreference('nightMode', false);
  // 用户 UI 字号：与系统字号相乘后再钳制（见 text_scale.dart）。
  static const uiFontScale = NumericPreference(
    'uiFontScale',
    1.0,
    min: 0.85,
    max: 1.30,
    step: 0.05,
  );
  // 繁简显示：打开后把漫画标题/简介/章节名里的繁体转简体显示。默认关闭。
  static const convertTraditionalToSimplified = BoolPreference(
    'convertTraditionalToSimplified',
    false,
  );
  static const all = <Preference<Object>>[
    themeMode,
    color,
    commentFontSize,
    nightMode,
    uiFontScale,
    convertTraditionalToSimplified,
  ];
}

abstract final class DiscoveryPreferences {
  static const comicDisplayMode = ChoicePreference(
    'comicDisplayMode',
    'detailed',
    ['detailed', 'brief'],
  );
  static const comicTileScale = NumericPreference(
    'comicTileScale',
    1.0,
    min: 0.5,
    max: 1.5,
    step: 0.05,
  );
  static const showFavoriteStatusOnTile = BoolPreference(
    'showFavoriteStatusOnTile',
    true,
  );
  static const showHistoryStatusOnTile = BoolPreference(
    'showHistoryStatusOnTile',
    false,
  );
  static const showDetailedReadingProgress = BoolPreference(
    'showDetailedReadingProgress',
    false,
  );
  static const showUpdateStatusOnTile = BoolPreference(
    'showUpdateStatusOnTile',
    true,
  );
  static const autoAddLanguageFilter = ChoicePreference(
    'autoAddLanguageFilter',
    'none',
    ['none', 'chinese', 'english', 'japanese'],
  );
  static const initialPage = StringIndexPreference(
    'initialPage',
    '0',
    length: 4,
  );
  // The existing editor writes "Continuous"; old lowercase values are aliases.
  static const comicListDisplayMode = ChoicePreference(
    'comicListDisplayMode',
    'paging',
    ['paging', 'Continuous'],
    aliases: {'continuous': 'Continuous'},
  );
  static const explorePages = StringListPreference('explore_pages');
  static const categoryPages = StringListPreference('categories');
  static const favoritePages = StringListPreference('favorites');
  static const searchSources = NullableStringListPreference('searchSources');
  static const defaultSearchTarget = NullableStringPreference(
    'defaultSearchTarget',
  );
  static const all = <Preference<Object?>>[
    comicDisplayMode,
    comicTileScale,
    showFavoriteStatusOnTile,
    showHistoryStatusOnTile,
    showDetailedReadingProgress,
    showUpdateStatusOnTile,
    autoAddLanguageFilter,
    initialPage,
    comicListDisplayMode,
    explorePages,
    categoryPages,
    favoritePages,
    searchSources,
    defaultSearchTarget,
  ];
}

abstract final class KeywordPreferences {
  static const comics = StringListPreference('blockedWords');
  static const comments = StringListPreference('blockedCommentWords');
  static const all = [comics, comments];
}

abstract final class FavoritePreferences {
  static const displayMode = ChoicePreference('favoritesDisplayMode', 'list', [
    'list',
    'gallery',
  ]);
  static const galleryColumns = AutoCountPreference(
    'favoritesGalleryColumns',
    min: 2,
    max: 6,
  );
  static const localFavoritesFirst = BoolPreference(
    'localFavoritesFirst',
    true,
  );
  static const autoCloseFavoritePanel = BoolPreference(
    'autoCloseFavoritePanel',
    false,
  );
  static const newFavoriteAddTo = ChoicePreference('newFavoriteAddTo', 'end', [
    'start',
    'end',
  ]);
  static const moveFavoriteAfterRead = ChoicePreference(
    'moveFavoriteAfterRead',
    'none',
    ['none', 'end', 'start'],
  );
  static const quickFavorite = NullableStringPreference('quickFavorite');
  static const onClickFavorite = ChoicePreference(
    'onClickFavorite',
    'viewDetail',
    ['viewDetail', 'read'],
  );
  static const readLaterFolder = NullableStringPreference('readLaterFolder');
  static const followUpdatesFolder = NullableStringPreference(
    'followUpdatesFolder',
  );
  static const all = <Preference<Object?>>[
    displayMode,
    galleryColumns,
    localFavoritesFirst,
    autoCloseFavoritePanel,
    newFavoriteAddTo,
    moveFavoriteAfterRead,
    quickFavorite,
    onClickFavorite,
    readLaterFolder,
    followUpdatesFolder,
  ];
}

abstract final class ImageProcessingPreferences {
  static const enabled = BoolPreference('enableCustomImageProcessing', false);
  static const script = StringPreference(
    'customImageProcessing',
    defaultCustomImageProcessing,
  );
  static const all = <Preference<Object>>[enabled, script];
}

const defaultCustomImageProcessing = '''
/**
 * Process an image
 * @param image {ArrayBuffer} - The image to process
 * @param cid {string} - The comic ID
 * @param eid {string} - The episode ID
 * @param page {number} - The page number
 * @param sourceKey {string} - The source key
 * @returns {Promise<ArrayBuffer> | {image: Promise<ArrayBuffer>, onCancel: () => void}} - The processed image
 */
async function processImage(image, cid, eid, page, sourceKey) {
    let futureImage = new Promise((resolve, reject) => {
        resolve(image);
    });
    return futureImage;
}
''';

Map<String, Object?> get applicationPreferenceDefaults => {
  for (final preference in [
    ...AppPreferences.all,
    ...NetworkPreferences.all,
    ...AppearancePreferences.all,
    ...DiscoveryPreferences.all,
    ...KeywordPreferences.all,
    ...FavoritePreferences.all,
    ...ImageProcessingPreferences.all,
  ])
    preference.key: preference.storageDefault,
};
