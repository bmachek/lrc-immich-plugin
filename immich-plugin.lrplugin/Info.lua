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
            title = "Import from Immich (Search)",
            file = "SmartSearchImportDialog.lua",
        },
        {
            title = "Find in Lightroom (Immich Search)",
            file = "SearchInLightroomDialog.lua",
        },
        {
            title = "Sync from Immich",
            file = "SyncFromImmichDialog.lua",
        },
        {
            title = "Create Immich share link",
            file = "ShareLinkDialog.lua",
        },
        {
            title = "Stamp imported Immich IDs",
            file = "StampImportedDialog.lua",
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
            title = "Import from Immich (Search)",
            file = "SmartSearchImportDialog.lua",
        },
        {
            title = "Find in Lightroom (Immich Search)",
            file = "SearchInLightroomDialog.lua",
        },
        {
            title = "Sync from Immich",
            file = "SyncFromImmichDialog.lua",
        },
        {
            title = "Create Immich share link",
            file = "ShareLinkDialog.lua",
        },
        {
            title = "Stamp imported Immich IDs",
            file = "StampImportedDialog.lua",
        },
        {
            title = "Immich import configuration",
            file = "ImportConfiguration.lua",
        },
    },

    LrPluginInfoProvider = "PluginInfo.lua",

    LrPluginInfoURL = "https://github.com/bmachek/lrc-immich-plugin/",

    VERSION = { major = 5, minor = 0, revision = 0, build = 0 },
}
