require "PublishDialogSections"
require "PublishTask"

return {
	
	hideSections = { 'exportLocation' },

	allowFileFormats = nil, 
	
	allowColorSpaces = nil,

	exportPresetFields = {
		{ key = 'url', default = nil },
		{ key = "apiKey", default = nil },
	},

	startDialog = PublishDialogSections.startDialog,
	sectionsForTopOfDialog = PublishDialogSections.sectionsForTopOfDialog,
	processRenderedPhotos = PublishTask.processRenderedPhotos,
	shouldRenderPhoto = PublishTask.shouldRenderPhoto,

	canExportVideo = true,

	supportsIncrementalPublish = 'only',

    small_icon = 'icons/logo.png',
}


