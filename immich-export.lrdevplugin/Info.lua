
return {

	LrSdkVersion = 3.0,
	LrSdkMinimumVersion = 3.0,

	LrToolkitIdentifier = 'org.immich.lightroom',

	LrPluginName = "Immich Plugin",
	
	LrExportServiceProvider = {
		title = "Immich Server",
		file = 'ImmichUploadServiceProvider.lua',
	},

	-- LrPluginInfoProvider = 'ImmichUploadInfoProvider.lua',

	VERSION = { major=0, minor=9, revision=0, build="20240605-beta", },

}
