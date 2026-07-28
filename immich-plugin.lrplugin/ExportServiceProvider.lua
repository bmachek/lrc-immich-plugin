require("ExportDialogSections")
require("ExportTask")

return {

    hideSections = { "exportLocation" },

    allowFileFormats = nil,

    allowColorSpaces = nil,

    exportPresetFields = {
        { key = "useGlobalConnection", default = false },
        { key = "url", default = "" },
        { key = "apiKey", default = "" },
        { key = "album", default = nil },
        { key = "albumMode", default = "none" },
        { key = "originalFileMode", default = "none" },
        { key = "stackOriginalExport", default = false },
        { key = "stackWithExistingOriginal", default = false },
        { key = "stackLrStacks", default = false },
        { key = "lockedFolderMode", default = "none" },
    },

    canExportVideo = true,

    startDialog = ExportDialogSections.startDialog,
    sectionsForTopOfDialog = ExportDialogSections.sectionsForTopOfDialog,
    sectionsForBottomOfDialog = ExportDialogSections.sectionsForBottomOfDialog,

    processRenderedPhotos = ExportTask.processRenderedPhotos,
}
