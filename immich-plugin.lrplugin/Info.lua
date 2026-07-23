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
            title = "Find in Lightroom (Immich Search)",
            file = "SearchInLightroomDialog.lua",
        },
        {
            title = "Create Immich share link",
            file = "ShareLinkDialog.lua",
        },
        {
            title = "Sync with Immich",
            file = "SyncDialog.lua",
        },
    },

    LrExportMenuItems = {
        {
            title = "Import from Immich",
            file = "ImportDialog.lua",
        },
        {
            title = "Find in Lightroom (Immich Search)",
            file = "SearchInLightroomDialog.lua",
        },
        {
            title = "Create Immich share link",
            file = "ShareLinkDialog.lua",
        },
        {
            title = "Sync with Immich",
            file = "SyncDialog.lua",
        },
    },

    LrHelpMenuItems = {
        {
            title = "Stamp imported Immich IDs",
            file = "StampImportedDialog.lua",
        },
        {
            title = "Pull metadata from Immich",
            file = "SyncFromImmichDialog.lua",
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
