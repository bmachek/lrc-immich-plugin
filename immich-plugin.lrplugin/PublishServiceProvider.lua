require "PublishDialogSections"
require "PublishTask"

return {

	hideSections = { 'exportLocation' },
	allowFileFormats = nil,
	allowColorSpaces = nil,
	canExportVideo = true,
	supportsCustomSortOrder = false,
	supportsIncrementalPublish = 'only',

	small_icon = 'icons/logo.png',

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


}
