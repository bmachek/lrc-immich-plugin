require "PublishDialogSections"
require "PublishTask"

return {
	startDialog = PublishDialogSections.startDialog,
	sectionsForTopOfDialog = PublishDialogSections.sectionsForTopOfDialog,
	sectionsForBottomOfDialog = PublishDialogSections.sectionsForBottomOfDialog,
	hideSections = { 'exportLocation' },
	allowFileFormats = nil,
	allowColorSpaces = nil,
	canExportVideo = true,
	supportsCustomSortOrder = false,
	supportsIncrementalPublish = 'only',


	exportPresetFields = {
		{ key = 'url', default = '' },
		{ key = "apiKey", default = '' },
		{ key = 'stackDngJpg', default = false },
		{ key = 'stackLrStacks', default = false },
	},

	small_icon = 'icons/logo_small.png',

	titleForPublishedCollection = 'Immich album',
	titleForPublishedSmartCollection = 'Immich album (Smart collection)',

	getCollectionBehaviorInfo = PublishTask.getCollectionBehaviorInfo,

	processRenderedPhotos = PublishTask.processRenderedPhotos,

	canAddCommentsToService = false,
	-- addCommentToPublishedPhoto = PublishTask.addCommentToPublishedPhoto,
	getCommentsFromPublishedCollection = PublishTask.getCommentsFromPublishedCollection,

	deletePhotosFromPublishedCollection = PublishTask.deletePhotosFromPublishedCollection,
	deletePublishedCollection = PublishTask.deletePublishedCollection,
	renamePublishedCollection = PublishTask.renamePublishedCollection,
	shouldDeletePhotosFromServiceOnDeleteFromCatalog = PublishTask.shouldDeletePhotosFromServiceOnDeleteFromCatalog,
	validatePublishedCollectionName = PublishTask.validatePublishedCollectionName,

	viewForCollectionSettings = PublishTask.viewForCollectionSettings,
	endDialogForCollectionSettings = PublishTask.endDialogForCollectionSettings,
	updateCollectionSettings = PublishTask.updateCollectionSettings,

}
