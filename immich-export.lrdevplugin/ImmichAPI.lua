local LrHttp = import 'LrHttp'
local LrDate = import 'LrDate'
local LrPathUtils = import 'LrPathUtils'
----------------------------------------------------------------------------
JSON = require "JSON"
local inspect = require 'inspect'

----------------------------------------------------------------------------


ImmichAPI = {}
local log = import 'LrLogger'( 'ImmichAPI' )
log:enable ( 'logfile' )


----------------------------------------------------------------------------


function ImmichAPI.uploadAsset( params, pathOrMessage )

	-- log:trace( 'uploadAsset: params: ',  inspect ( params ) )
	log:trace( 'uploadAsset: pathOrMessage: ', pathOrMessage )

	local uploadUrl = params.url .. '/api/asset/upload'
	log:trace( 'uploadAsset: uploadUrl: ', uploadUrl )

	local submitDate = LrDate.timeToIsoDate( LrDate.currentTime() )

	local filePath = assert( pathOrMessage )
	log:trace( 'uploadAsset: filePath', filePath )
	local fileName = LrPathUtils.leafName( filePath )
		
	local headerChunks = {}
	headerChunks[ #headerChunks + 1 ] = { field = 'x-api-key', value = params.apiKey }
	headerChunks[ #headerChunks + 1 ] = { field = 'Accept', value = 'application/json' }
	
	local mimeChunks = {}
	mimeChunks[ #mimeChunks + 1 ] = { name = 'assetData', filePath = filePath, fileName = fileName, contentType = 'application/octet-stream' }
	mimeChunks[ #mimeChunks + 1 ] = { name = 'deviceAssetId', value = fileName }
	mimeChunks[ #mimeChunks + 1 ] = { name = 'deviceId', value = 'Lightroom Immich Upload Plugin' }
	mimeChunks[ #mimeChunks + 1 ] = { name = 'fileCreatedAt', value = submitDate }
	mimeChunks[ #mimeChunks + 1 ] = { name = 'fileModifiedAt', value = submitDate }
	mimeChunks[ #mimeChunks + 1 ] = { name = 'isFavorite', value = 'false' }

	local result, hdrs = LrHttp.postMultipart( uploadUrl, mimeChunks, headerChunks )

	if not result then
	
		if hdrs and hdrs.error then -- NOK
			log:error( 'POST response headers: ', inspect ( hdrs ) )
			LrErrors.throwUserError( "Error uploading some assets, please consult logs." )
			
		elseif hdrs then -- NOK
			log:trace( 'POST response headers: ', inspect ( hdrs ) )
		end
	else -- OK
		log:trace( 'POST response body: ', result)
		local parsedResult = JSON:decode ( result )
		log:trace ( 'Parsed POST response body', inspect ( parsedResult ) )
		return parsedResult.id
	end

end


function ImmichAPI.addAssetToAlbum ( params, albumId, assetId )

	local addUrl = params.url .. '/api/album/' .. albumId .. '/assets'

	local headerChunks = {}
	headerChunks[ #headerChunks + 1 ] = { field = 'x-api-key', value = params.apiKey }
	headerChunks[ #headerChunks + 1 ] = { field = 'Accept', value = 'application/json' }
	headerChunks[ #headerChunks + 1 ] = { field = 'Content-Type', value = 'application/json' }
		
	local postBody = {}
	local ids = { assetId }

	postBody.ids = ids

	log:trace ( 'addAssetToAlbum: ' .. JSON:encode(postBody ) )

	local result, hdrs = LrHttp.post( addUrl, JSON:encode(postBody), headerChunks, 'PUT', 5 )

	if not result then
		log:error ( 'Empty result from Immich server.' )
		if hdrs and hdrs.error then
			log:error( 'PUT response headers: ', inspect ( hdrs ) )
			LrErrors.throwUserError( "Error adding asset to album, please consult logs." )
			
		elseif hdrs then
			log:trace( 'GET response headers: ', inspect ( hdrs ) )
		elseif not hdrs then  
			log:error( 'Empty headers from Immich server' )
		end
	else
		local decoded = {}
		decoded = JSON:decode ( result )
		-- log:trace ( inspect ( decoded ) )

		if decoded.success == False then
			log:error ("Unable to add asset (" .. assetId .. ") to album (" .. albumId .. ").")
			log:error ( inspect ( decoded ) )
		end

	end

end

----------------------------------------------------------------------------

function ImmichAPI.createAlbum ( params, albumName )
	local addUrl = params.url .. '/api/album'

	local headerChunks = {}
	headerChunks[ #headerChunks + 1 ] = { field = 'x-api-key', value = params.apiKey }
	headerChunks[ #headerChunks + 1 ] = { field = 'Accept', value = 'application/json' }
	headerChunks[ #headerChunks + 1 ] = { field = 'Content-Type', value = 'application/json' }
		
	local postBody = {}
	postBody.albumName = albumName
	log:trace('Album create POST body: ' .. inspect (postBody))

	local result, hdrs = LrHttp.post( addUrl, JSON:encode(postBody), headerChunks )

	if not result then
		log:error ( 'Empty result from Immich server.' )
		if hdrs and hdrs.error then
			log:error( 'POST response headers: ', inspect ( hdrs ) )			
		elseif hdrs then
			log:trace( 'POST response headers: ', inspect ( hdrs ) )
		elseif not hdrs then  
			log:error( 'Empty headers from Immich server' )
		end
		log:error ('Error creating album.')
	else
		local decoded = {}
		decoded = JSON:decode ( result )
		-- log:trace ( inspect ( decoded ) )

		if decoded.id == nil then
			log:error("Unable creating album (" .. albumName .. ").")
			-- LrErrors.throwUserError( "Error creating album, please consult logs." )
		else 
			log:trace ( 'Album successfully created with id: ' .. decoded.id )
			return decoded.id
		end

	end

end


function ImmichAPI.deleteAlbum ( params, albumId )
	local addUrl = params.url .. '/api/album/' .. albumId

	local headerChunks = {}
	headerChunks[ #headerChunks + 1 ] = { field = 'x-api-key', value = params.apiKey }
	headerChunks[ #headerChunks + 1 ] = { field = 'Accept', value = 'application/json' }
	headerChunks[ #headerChunks + 1 ] = { field = 'Content-Type', value = 'application/json' }
		
	local result, hdrs = LrHttp.post( addUrl, JSON:encode(postBody), headerChunks, 'DELETE', 5 )

	if not result then
		log:error ( 'Empty result from Immich server.' )
		if hdrs and hdrs.error then
			log:error( 'POST response headers: ', inspect ( hdrs ) )
			LrErrors.throwUserError( "Error deleting album, please consult logs." )
			
		elseif hdrs then
			log:trace( 'POST response headers: ', inspect ( hdrs ) )
		elseif not hdrs then  
			log:error( 'Empty headers from Immich server' )
		end
	else
		local decoded = {}
		decoded = JSON:decode ( result )
		-- log:trace ( inspect ( decoded ) )

		if decoded.success == False then
			log:error("Unable to delete album (" .. albumName .. ").")
			LrErrors.throwUserError( "Error deleting album, please consult logs." )
		else 
			return decoded.id
		end

	end

end

function ImmichAPI.getAlbums( url, apiKey )

	local getUrl = url .. '/api/album'
	log:trace( 'getAlbums: getURL: ', getUrl )

	local headerChunks = {}
	headerChunks[ #headerChunks + 1 ] = { field = 'x-api-key', value = apiKey }
	headerChunks[ #headerChunks + 1 ] = { field = 'Accept', value = 'application/json' }
	
	local mimeChunks = {} 

	log:trace( 'getAlbums: header chunks', inspect( headerChunks) )

	local result, hdrs = LrHttp.get( getUrl, headerChunks, 5 )

	log:trace( 'getAlbums: request sent' )

	local albums = {}

	if not result then
		log:error ( 'Empty result from Immich server.' )
		if hdrs and hdrs.error then
			log:error( 'GET response headers: ', inspect ( hdrs ) )
			LrErrors.throwUserError( "Error getting album list from Immich, please consult logs." )
			
		elseif hdrs then
			log:trace( 'GET response headers: ', inspect ( hdrs ) )
		elseif not hdrs then  
			log:error( 'Empty headers from Immich server' )
		end
	else
		-- log:trace( 'POST response body: ', result)
		local decoded = {}
		decoded = JSON:decode ( result )
		-- log:trace ( inspect ( decoded ) )

		local name = ""
		local uuid = ""

		for i = 1, #decoded do
			row = decoded[i]
			name = row.albumName
			uuid = row.id
			createdAt = string.sub ( row.createdAt, 1, 19 )
			log:trace( 'UUID: ' .. uuid .. ' -- Date: ' .. createdAt .. " -- Name: " .. name )

			local rowTable = {}
			rowTable.title = name .. ' (' .. createdAt .. ')' 
			rowTable.value = uuid
			table.insert ( albums, rowTable )
		end
		  
	end

	return albums

end

