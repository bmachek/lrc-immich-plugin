-- Licensed under the GNU General Public License v3.0 (GPL-3.0).
-- See the LICENSE file in the repository root for details.

return {

    LrSdkVersion = 3.0,
    LrSdkMinimumVersion = 3.0,

    LrToolkitIdentifier = "lrc-immich-plugin",

    LrPluginName = "Immich",

    LrInitPlugin = "Init.lua",

    LrExportServiceProvider = {
        {
            title = "Immich Exporter",
            file = "ExportServiceProvider.lua",
        },
        {
            title = "Immich Publisher",
            file = "PublishServiceProvider.lua",
        },
    },

    LrMetadataProvider = "MetadataProvider.lua",

    LrLibraryMenuItems = {
        {
            title = "Import from Immich",
            file = "ImportDialog.lua",
        },
        {
            title = "Immich import configuration",
            file = "ImportConfiguration.lua",
        },
        {
            title = "Reset Immich IDs for selected photos",
            file = "ResetImmichIds.lua",
            enabledWhen = "photosSelected",
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

    LrPluginInfoProvider = "PluginInfo.lua",

    LrPluginInfoURL = "https://github.com/bmachek/lrc-immich-plugin/",

    VERSION = { major = 4, minor = 3, revision = 2, build = 0 },
}
