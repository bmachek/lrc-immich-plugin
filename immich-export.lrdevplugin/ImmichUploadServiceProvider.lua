-- ImmichUpload plug-in
require "ImmichUploadExportDialogSections"
require "ImmichUploadTask"
local prefs = import 'LrPrefs'.prefsForPlugin() 


return {
	
	hideSections = { 'exportLocation' },

	allowFileFormats = nil, 
	
	allowColorSpaces = nil,

	exportPresetFields = {
		{ key = 'url', default = nil },
		{ key = "apiKey", default = nil },
		{ key = 'album', default = nil },
		{ key = 'albumMode', default = nil },
	},

	startDialog = ImmichUploadExportDialogSections.startDialog,
	sectionsForTopOfDialog = ImmichUploadExportDialogSections.sectionsForTopOfDialog,
	sectionsForBottomOfDialog = ImmichUploadExportDialogSections.sectionsForBottomOfDialog,
	
	processRenderedPhotos = ImmichUploadTask.processRenderedPhotos,
	
}
