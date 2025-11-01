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

	LrPluginInfoURL = 'https://blog.fokuspunk.de/lrc-immich-plugin/',

	VERSION = { major = 3, minor = 3, revision = 0, build = 0, },

}
