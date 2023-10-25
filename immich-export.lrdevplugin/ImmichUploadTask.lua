
-- Lightroom API
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrErrors = import 'LrErrors'
local LrDialogs = import 'LrDialogs'
local LrHttp = import 'LrHttp'
local LrDate = import 'LrDate'

--============================================================================--

ImmichUploadTask = {}
local log = import 'LrLogger'( 'ImmichUploadTask' )
log:enable ( 'logfile' )


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

	log:trace( 'uploadFileToImmmich: params: ',  dumpTable ( params ) )
	log:trace( 'uploadFileToImmmich: pathOrMessage: ', pathOrMessage )

	local postUrl = params.url .. '/api/asset/upload'
	log:trace( 'uploadFileToImmmich: postURL: ', postUrl )

	local submitDate = LrDate.timeToIsoDate( LrDate.currentTime() )
	local filePath = assert( pathOrMessage )
	log:trace( 'uploadFileToImmmich: filePath', filePath )
	local fileName = LrPathUtils.leafName( filePath )

	local headerChunks = {}
	headerChunks[ #headerChunks + 1 ] = { field = 'x-api-key', value = params.apiKey }
	
	local mimeChunks = {}
	mimeChunks[ #mimeChunks + 1 ] = { name = 'assetData', filePath = filePath, fileName = fileName, contentType = 'application/octet-stream' }
	mimeChunks[ #mimeChunks + 1 ] = { name = 'deviceAssetId', value = fileName }
	mimeChunks[ #mimeChunks + 1 ] = { name = 'deviceId', value = 'Lightroom Immich Upload Plugin' }
	mimeChunks[ #mimeChunks + 1 ] = { name = 'fileCreatedAt', value = submitDate }
	mimeChunks[ #mimeChunks + 1 ] = { name = 'fileModifiedAt', value = submitDate }
	mimeChunks[ #mimeChunks + 1 ] = { name = 'isFavorite', value = 'false' }

	local result, hdrs = LrHttp.postMultipart( postUrl, mimeChunks, headerChunks )

	if not result then
	
		if hdrs and hdrs.error then
			log:error( 'POST response headers: ', dumpTable ( hdrs ) )
			LrErrors.throwUserError( "Error uploading some assets, please consult logs." )
			
		elseif hdrs then
			log:trace( 'POST response headers: ', dumpTable ( hdrs ) )
		end
	else
		log:trace( 'POST response body: ', result)
	end

end

-- Taken from https://gist.github.com/marcotrosi/163b9e890e012c6a460a
-- Copyright https://gist.github.com/marcotrosi

function dumpTable(t)
	local result = ''

	local function printTableHelper(obj, cnt)
	
		local cnt = cnt or 0
	
		if type(obj) == "table" then
	
			result = result .. " ", string.rep("\t", cnt), "{ "
			cnt = cnt + 1
	
			for k,v in pairs(obj) do
				if not k == nil then
					if type(k) == "string" then
						result = result .. string.rep("\t",cnt), '["'..k..'"]', ' = '
					end
		
					if type(k) == "number" then
						result = result .. string.rep("\t",cnt), "["..k.."]", " = "
					end
				end

				if not v == nil then
					printTableHelper(v, cnt)
				end

				printTableHelper(v, cnt)
				result = result .. ", "
			end
	
			cnt = cnt-1
			result = result .. string.rep("\t", cnt), "}"
	
		elseif type(obj) == "string" then
			result = result .. string.format("%q", obj)
	
		else
			result = result .. tostring(obj)
		end 
	end
	
	printTableHelper(t)

	return result
end