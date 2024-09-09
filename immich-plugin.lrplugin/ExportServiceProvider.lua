require "ExportDialogSections"
require "ExportTask"

return {

	hideSections = { 'exportLocation' },

	allowFileFormats = nil,

	allowColorSpaces = nil,

	exportPresetFields = {
		{ key = 'url', default = '' },
		{ key = "apiKey", default = '' },
		{ key = 'album',     default = nil },
		{ key = 'albumMode', default = nil },
	},

	canExportVideo = true,

	startDialog = ExportDialogSections.startDialog,
	sectionsForTopOfDialog = ExportDialogSections.sectionsForTopOfDialog,
	sectionsForBottomOfDialog = ExportDialogSections.sectionsForBottomOfDialog,

	processRenderedPhotos = ExportTask.processRenderedPhotos,

}
