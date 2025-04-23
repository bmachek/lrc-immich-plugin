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

	LrLibraryMenuItems = {
		{
			title = "Import from Immich",
			file = "ImportDialog.lua",
		},
		{
			title = "Immich import configuration",
			file = "ImportConfiguration.lua",
		},
	},

	LrExportMenuItems = {
		{
			title = "Import from Immich",
			file = "ImportDialog.lua",
		},
		{
			title = "Immich import configuration",
			file = "ImportConfiguration.lua",
		},
	},

	LrPluginInfoProvider = 'PluginInfo.lua',

	LrPluginInfoURL = 'https://github.com/bmachek/lrc-immich-plugin',

	VERSION = { major = 2, minor = 5, revision = 1, build = 0, },

}
