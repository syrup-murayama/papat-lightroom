return {
  LrSdkVersion = 6.0,
  LrSdkMinimumVersion = 6.0,
  LrToolkitIdentifier = 'app.papat.lightroom',
  LrPluginName = 'papat',
  LrPluginInfoUrl = 'https://papat.app/lightroom/',
  LrPluginInfoProvider = 'PluginInfoProvider.lua',
  LrMetadataProvider = 'Metadata.lua',
  LrMetadataTagsetFactory = 'Tagset.lua',
  VERSION = { major = 1, minor = 2, revision = 3, build = 0 },
  LrLibraryMenuItems = {
    {
      title = 'papat でギャラリーを作る…',
      file = 'CreateGallery.lua',
    },
    {
      title = 'papat のセレクトを読み込む…',
      file = 'ImportSelections.lua',
    },
    {
      title = 'papat 最近のギャラリー…',
      file = 'RecentGalleries.lua',
    },
  },
}
