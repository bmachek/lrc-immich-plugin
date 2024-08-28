require "PublishDialogSections"
require "PublishTask"

return {
	
	hideSections = { 'exportLocation' },
	allowFileFormats = nil, 
	allowColorSpaces = nil,
	canAddCommentsToService = true,
	canExportVideo = true,
	supportsIncrementalPublish = 'only',
    small_icon = 'icons/logo.png',
	supportsCustomSortOrder = false,
	titleForPublishedCollection = 'Immich album',
	titleForPublishedSmartCollection = 'Immich album (Smart collection)',

	-- shouldRenderPhoto = true, -- Sufficient???

	startDialog = PublishDialogSections.startDialog,
	sectionsForTopOfDialog = PublishDialogSections.sectionsForTopOfDialog,


	processRenderedPhotos = PublishTask.processRenderedPhotos,
		
	addCommentToPublishedPhoto = PublishTask.addCommentToPublishedPhoto,
	getCommentsFromPublishedCollection = PublishTask.getCommentsFromPublishedCollection,
	
	deletePhotosFromPublishedCollection = PublishTask.deletePhotosFromPublishedCollection,

	deletePublishedCollection = PublishTask.deletePublishedCollection,
	renamePublishedCollection = PublishTask.renamePublishedCollection,
	shouldDeletePhotosFromServiceOnDeleteFromCatalog = PublishTask.shouldDeletePhotosFromServiceOnDeleteFromCatalog,



}


