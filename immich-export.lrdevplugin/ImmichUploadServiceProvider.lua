-- ImmichUpload plug-in
require "ImmichUploadExportDialogSections"
require "ImmichUploadTask"


return {
	
	hideSections = { 'exportLocation' },

	allowFileFormats = nil, 
	
	allowColorSpaces = nil,

	exportPresetFields = {
		{ key = 'url', default = nil },
		{ key = "apiKey", default = nil },
	},

	startDialog = ImmichUploadExportDialogSections.startDialog,
	sectionsForBottomOfDialog = ImmichUploadExportDialogSections.sectionsForBottomOfDialog,
	
	processRenderedPhotos = ImmichUploadTask.processRenderedPhotos,
	
}
