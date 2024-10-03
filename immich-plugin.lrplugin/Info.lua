return {

	LrSdkVersion = 3.0,
	LrSdkMinimumVersion = 3.0,

	LrToolkitIdentifier = 'lrc-immich-plugin',

	LrPluginName = "Immich",

	LrInitPlugin = "Init.lua",

	LrExportServiceProvider = {
		{
			title = "Immich Exporter",
			file = 'ExportServiceProvider.lua',
		},
		{
			title = "Immich Publisher",
			file = 'PublishServiceProvider.lua',
		},
	},

	-- LrMetadataProvider = 'MetadataProvider.lua',

	LrPluginInfoProvider = 'PluginInfo.lua',

	LrPluginInfoURL = 'https://github.com/bmachek/lrc-immich-plugin',

	VERSION = { major = 2, minor = 2, revision = 2, build = "", },

}
