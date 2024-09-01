require "ExportDialogSections"
require "ExportTask"

return {

	hideSections = { 'exportLocation' },

	allowFileFormats = nil,

	allowColorSpaces = nil,

	exportPresetFields = {
		-- { key = 'url', default = prefs.url },
		-- { key = "apiKey", default = prefs.apiKey },
		{ key = 'album',     default = nil },
		{ key = 'albumMode', default = nil },
	},

	canExportVideo = true,

	startDialog = ExportDialogSections.startDialog,
	sectionsForTopOfDialog = ExportDialogSections.sectionsForTopOfDialog,
	-- sectionsForBottomOfDialog = ExportDialogSections.sectionsForBottomOfDialog,

	processRenderedPhotos = ExportTask.processRenderedPhotos,

}
