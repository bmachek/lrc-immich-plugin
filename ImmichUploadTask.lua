
-- Lightroom API
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrErrors = import 'LrErrors'
local LrDialogs = import 'LrDialogs'
local LrHttp = import 'LrHttp'
local LrDate = import 'LrDate'

--============================================================================--

ImmichUploadTask = {}

--------------------------------------------------------------------------------

function ImmichUploadTask.processRenderedPhotos( functionContext, exportContext )

	-- Make a local reference to the export parameters.
	
	local exportSession = exportContext.exportSession
	local exportParams = exportContext.propertyTable

	-- Set progress title.

	local nPhotos = exportSession:countRenditions()

	local progressScope = exportContext:configureProgress {
						title = nPhotos > 1
							   and LOC( "$$$/ImmichUpload/Upload/Progress=Uploading ^1 photos to Immich server", nPhotos )
							   or LOC "$$$/ImmichUpload/Upload/Progress/One=Uploading one photo to Immich server",
					}


	-- Iterate through photo renditions.
	
	local failures = {}

	for _, rendition in exportContext:renditions{ stopIfCanceled = true } do
	
		-- Wait for next photo to render.

		local success, pathOrMessage = rendition:waitForRender()
		
		-- Check for cancellation again after photo has been rendered.
		
		if progressScope:isCanceled() then break end
		
		if success then

			local success = uploadFileToImmich( exportParams, pathOrMessage )
			
			if not success then
			
				-- If we can't upload that file, log it.  For example, maybe user has exceeded disk
				-- quota, or the file already exists and we don't have permission to overwrite, or
				-- we don't have permission to write to that directory, etc....
				
				table.insert( failures, filename )
			end
					
			-- When done with photo, delete temp file. There is a cleanup step that happens later,
			-- but this will help manage space in the event of a large upload.
			
			LrFileUtils.delete( pathOrMessage )
					
		end
		
	end
	
	if #failures > 0 then
		local message
		if #failures == 1 then
			message = LOC "$$$/ImmichUpload/Upload/Errors/OneFileFailed=1 file failed to upload correctly."
		else
			message = LOC ( "$$$/ImmichUpload/Upload/Errors/SomeFileFailed=^1 files failed to upload correctly.", #failures )
		end
		LrDialogs.message( message, table.concat( failures, "\n" ) )
	end
	
end


function uploadFileToImmich( params, pathOrMessage )


	-- LrDialogs.message( 'params' , params )
	-- LrDialogs.message( 'pathOrMessage', pathOrMessage )

	local postUrl = params.url .. '/api/asset/upload'
	-- LrDialogs.message( 'postURL', postUrl )
	local contents = LrFileUtils.readFile( pathOrMessage )
	-- local size, creationDate, modificationDate = LrFileUtils.fileAttributes( pathOrMessage )

	local submitDate = LrDate.timeToIsoDate( LrDate.currentTime() )
	local filePath = assert( pathOrMessage )
	local fileName = LrPathUtils.leafName( filePath )

	local headerChunks = {}
	headerChunks[ #headerChunks + 1 ] = { field = 'x-api-key', value = params.apiKey }
	
	local mimeChunks = {}
	-- LrDialogs.message( 'filePath', filePath )
	-- LrDialogs.message( 'fileName', fileName )
	mimeChunks[ #mimeChunks + 1 ] = { name = 'assetData', filePath = filePath, fileName = fileName, contentType = 'application/octet-stream' }
	mimeChunks[ #mimeChunks + 1 ] = { name = 'deviceAssetId', value = fileName }
	mimeChunks[ #mimeChunks + 1 ] = { name = 'deviceId', value = 'Lightroom Immich Upload Plugin' }
	mimeChunks[ #mimeChunks + 1 ] = { name = 'fileCreatedAt', value = submitDate }
	mimeChunks[ #mimeChunks + 1 ] = { name = 'fileModifiedAt', value = submitDate }
	mimeChunks[ #mimeChunks + 1 ] = { name = 'isFavorite', value = 'false' }
	-- mimeChunks[ #mimeChunks + 1 ] = { name = 'key', value = params.apiKey }

	local result, hdrs = LrHttp.postMultipart( postUrl, mimeChunks, headerChunks )

	LrDialogs.message( 'result', result )
	-- LrDialogs.message( 'hdrs', hdrs )

	if not result then
	
		if hdrs and hdrs.error then
			LrErrors.throwUserError( formatError( hdrs.error.nativeCode ) )
		end
		
	end

end
