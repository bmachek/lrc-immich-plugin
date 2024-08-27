
ImmichAPI = {}
ImmichAPI.__index = ImmichAPI


function ImmichAPI:new(url, apiKey)
    local o = setmetatable({}, ImmichAPI)
    self.apiKey = apiKey
    self.deviceIdString = 'Lightroom Immich Upload Plugin'
    self.apiBasePath = '/api'
    self.url = url
    -- o:checkConnectivity()
    return o
end

local function generateMultiPartBody(b, formData, filePath)

    local fileName = LrPathUtils.leafName(filePath)
    local body = ''
    local boundary = '--' .. b .. '\r\n'

    for i = 1, #formData do
        body = body .. boundary
        for k,v in pairs(formData[i]) do
            if k == 'name' then
                body = body .. 'Content-Disposition: form-data; name="' .. v .. '"\r\n\r\n'
            elseif k == 'value' then
                body = body .. v .. "\r\n"
            end
        end
    end

    local fh = io.open(filePath, "rb")
    local fileContent = fh:read("*all")
    fh:close()

    log:trace(fileContent)

    body = body .. boundary
    body = body .. 'Content-Disposition: form-data; name="assetData"; filename="' .. fileName .. '"\r\n'
    body = body .. 'Content-Type: application/octet-stream\r\n\r\n'
    body = body .. fileContent
    body = body .. '\r\n--' .. b .. '--' .. '\r\n'

    return body
end

-- Utility function to create headers
function ImmichAPI:createHeaders()
    return {
        { field = 'x-api-key', value = self.apiKey },
        { field = 'Accept', value = 'application/json' },
        { field = 'Content-Type', value = 'application/json' },
    }
end


function ImmichAPI:createHeadersForMultipart()
    return {
        { field = 'x-api-key', value = self.apiKey },
        { field = 'Accept', value = 'application/json' },
    }
end


function ImmichAPI:createHeadersForMultipartPut(boundary, length)
    return {
        { field = 'x-api-key', value = self.apiKey },
        { field = 'Accept', value = 'application/json' },
        { field = 'Content-Type', value = 'multipart/form-data;boundary="' .. boundary .. '"' },
        { field = 'Content-Length', value = length },
    }
end

function ImmichAPI:sanityCheckAndFixURL(url)
    if not url then
        util.handleError('sanityCheckAndFixURL: URL is empty', "Error: Immich server URL is empty.")
        return false
    end

    local sanitizedURL = string.match(url, "^https?://[%w%.%-]+[:%d]*")
    if sanitizedURL then
        if string.len(sanitizedURL) == string.len(url) then
            log:trace('sanityCheckAndFixURL: URL is completely sane.')
            url = sanitizedURL
        else
            log:trace('sanityCheckAndFixURL: Fixed URL: removed trailing paths.')
            url = sanitizedURL
        end
    elseif not string.match(url, "^https?://") then
        util.handleError('sanityCheckAndFixURL: URL is missing protocol (http:// or https://).')
    else
        util.handleError('sanityCheckAndFixURL: Unknown error in URL')
    end
    
    return url
end

function ImmichAPI:checkConnectivity()
    log:trace('checkConnectivity: Sending getMyUser request')

    local decoded = ImmichAPI:doGetRequest('/users/me')

    if decoded then
        log:trace('checkConnectivity: test OK.')
        -- LrDialogs.message('Connection test successful.')
        return true
    else
        log:trace('checkConnectivity: test failed.' .. util.dumpTable(decoded))
        return false
    end
end

-- Thanks to Min Idzelis
function ImmichAPI:getAlbumUrl(albumId)
    return self.url .. '/albums/' .. albumId
end

-- Thanks to Min Idzelis
function ImmichAPI:getAssetUrl(id)
    return self.url .. '/photos/' .. id
end

function ImmichAPI:uploadAsset(pathOrMessage, localId)
    local apiPath = '/assets'
    local submitDate = LrDate.timeToIsoDate(LrDate.currentTime())
    local filePath = pathOrMessage
  	local fileName = LrPathUtils.leafName(filePath)

    local mimeChunks = {
        { name = 'assetData', filePath = filePath, fileName = fileName, contentType = 'application/octet-stream' },
        { name = 'deviceAssetId', value = localId },
        { name = 'deviceId', value = self.deviceIdString },
        { name = 'fileCreatedAt', value = submitDate },
        { name = 'fileModifiedAt', value = submitDate },
        { name = 'isFavorite', value = 'false' }
    }

	-- log:trace('uploadAsset: mimeChunks' .. util.dumpTable(mimeChunks))
    parsedResult = ImmichAPI:doMultiPartPostRequest(apiPath, mimeChunks)
    if parsedResult.id == nil then
        log:error('uploadAsset: Immich server did not retur an asset id')
        log:error('uploadAsset: Returned result: ' .. util.dumpTable(parsedResult))
        log:error('uploadAsset: Returned headers: ' .. util.dumpTable(hdr))
    end
    return parsedResult.id
end

function ImmichAPI:replaceAsset(immichId, pathOrMessage, localId)
    local apiPath = '/assets/' .. immichId .. '/original'
    local submitDate = LrDate.timeToIsoDate(LrDate.currentTime())
    local filePath = pathOrMessage
  	local fileName = LrPathUtils.leafName(filePath)

    local formData = {
        -- { name = 'assetData', filePath = filePath, fileName = fileName, contentType = 'application/octet-stream' },
        { name = 'deviceAssetId', value = localId },
        { name = 'deviceId', value = self.deviceIdString },
        { name = 'fileCreatedAt', value = submitDate },
        { name = 'fileModifiedAt', value = submitDate },
    }

	-- log:trace('uploadAsset: mimeChunks' .. util.dumpTable(mimeChunks))
    parsedResult = ImmichAPI:doMultiPartPutRequest(apiPath, pathOrMessage, formData)
    if parsedResult.id == nil then
        log:error('replaceAsset: Immich server did not return an asset id')
        log:error('replaceAsset: Returned result: ' .. util.dumpTable(parsedResult))
        log:error('replaceAsset: Returned headers: ' .. util.dumpTable(hdr))
        return nil
    end
    return parsedResult.id
end

function ImmichAPI:removeAssetFromAlbum(albumId, assetId)
    local apiPath = '/albums/' .. albumId .. '/assets'
    local postBody = { ids = { assetId } }

    local decoded = ImmichAPI:doCustomRequest('DELETE', apiPath, postBody)
    if not decoded then
        log:error("Unable to remove asset (" .. assetId .. ") from album (" .. albumId .. ").")
    end
end

function ImmichAPI:addAssetToAlbum(albumId, assetId)
    local apiPath = '/albums/' .. albumId .. '/assets'
    local postBody = { ids = { assetId } }

    local decoded = ImmichAPI:doCustomRequest('PUT', apiPath, postBody)
    if not decoded then
        log:error("Unable to add asset (" .. assetId .. ") to album (" .. albumId .. ").")
    end
end

function ImmichAPI:createAlbum(albumName)
    local apiPath = '/albums'
    local postBody = { albumName = albumName }

    local decoded = ImmichAPI:doPostRequest(apiPath, postBody)
    if not decoded.id then
        util.handleError("Unable to create album (" .. albumName .. ").", "Error creating album, please consult logs.")
        return nil
    else
        return decoded.id
    end
end

function ImmichAPI:deleteAlbum(albumId)
    local path = '/albums/' .. albumId

    local decoded = ImmichAPI:doCustomRequest('DELETE', path)
    if not decoded.success then
        util.handleError("Unable to delete album (" .. albumId .. ").", "Error deleting album, please consult logs.")
        return false
    else
        return true
    end
end

function ImmichAPI:renameAlbum(albumId, newName)
    local path = '/albums/' .. albumId

    local postBody = {}
    postBody.albumName = newName

    local decoded = ImmichAPI:doCustomRequest('PATCH', path, postBody)
    if not decoded.success then
        util.handleError("Unable to rename album (" .. albumId .. ").", "Error renaming album, please consult logs.")
        return false
    else
        return true
    end
end

function ImmichAPI:getAlbums()

    local path =  '/albums'
    local decoded = ImmichAPI:doGetRequest(path)
    local albums = {}
    if decoded then
        for i = 1, #decoded do
            local row = decoded[i]
            table.insert(albums, { title = row.albumName .. ' (' .. string.sub(row.createdAt, 1, 19) .. ')', value = row.id })
        end
        return albums
    else 
        return nil
    end    
end


function ImmichAPI:checkIfAssetExists(localId, filename, dateCreated)

    local id = tostring(localId)

    local postBody = { deviceAssetId = id, deviceId = self.deviceIdString, isTrashed = false }
    local response = ImmichAPI:doPostRequest('/search/metadata', postBody)

    if not response then
        log:trace('Asset with deviceAssetId ' .. id .. ' not found. No response')
		return nil
    elseif response.assets.count >= 1 then
        log:trace('Found existing asset with deviceAssetId ' .. tostring(localId))
        return response.assets.items[1].id, response.assets.items[1].deviceAssetId
	else
		log:trace('Asset with deviceAssetId ' .. id .. ' not found')
		
		postBody = { originalFileName = filename, takenAfter = dateCreated, takenBefore = dateCreated, isTrashed = false }
		response = ImmichAPI:doPostRequest('/search/metadata', postBody)
		
		if not response then
			log:trace('No asset with originalFilename ' .. filename .. ' and creationDate ' .. dateCreated .. ' found')
			return nil
		elseif response.assets.count >= 1 then
			log:trace('Found existing asset with filename  ' .. filename .. ' and creationDate ' ..  dateCreated)
			return response.assets.items[1].id, response.assets.items[1].deviceAssetId 
		end
    end
end

function ImmichAPI:checkIfAlbumExists(albumId)
    if albumId == nil then
        return false
    end 
    log:trace("ImmichAPI: checkIfAlbumExists")
    local albumInfo = ImmichAPI:doGetRequest('/albums/' .. albumId)
    if albumInfo.id == nil then 
        return false
    else 
        return true
    end
end

function ImmichAPI:getAlbumInfo(albumId) 
    log:trace("ImmichAPI: getAlbumInfo for: " .. albumId)
    local albumInfo = ImmichAPI:doGetRequest('/albums/' .. albumId)
    return albumInfo
end

function ImmichAPI:getAlbumAssetIds(albumId)
    log:trace("ImmichAPI: getAlbumAssetIds for: " .. albumId)
    local albumInfo = ImmichAPI:doGetRequest('/albums/' .. albumId)
    local assetIds = {}

    if not albumInfo.assets == nil then
        for i = 1, #albumInfo.assets do
            tables.insert(assetIds, albumInfo.assets[i].id)
        end
    end
    
    return assetIds

end

function ImmichAPI:doPostRequest(apiPath, postBody)
    log:trace('ImmichAPI: Preparing POST request ' .. apiPath)
    local result, hdrs = LrHttp.post(self.url .. self.apiBasePath .. apiPath, JSON:encode(postBody), ImmichAPI:createHeaders())
    
    if not result then
        log:error('ImmichAPI POST request failed. ' .. apiPath)
        return false
    else
        log:trace('ImmichAPI POST request succeeded: ' .. result)
        local decoded = JSON:decode(result)
        return decoded
    end
end

function ImmichAPI:doCustomRequest(method, apiPath, postBody)
    log:trace('ImmichAPI: Preparing ' .. method .. ' request ' .. apiPath)
    local url = self.url .. self.apiBasePath .. apiPath

    local result, hdrs = LrHttp.post(url, JSON:encode(postBody), ImmichAPI:createHeaders(), method, 5)
    
    if not result then
        log:error('ImmichAPI POST request failed. ' .. apiPath)
        log:error(util.dumpTable(hdrs))
        return false
    else
        log:trace('ImmichAPI POST request succeeded: ' .. result)
        local decoded = JSON:decode(result)
        return decoded
    end
end

function ImmichAPI:doGetRequest(apiPath)
    log:trace('ImmichAPI: Preparing GET request ' .. apiPath)
    -- log:trace(util.dumpTable(self))
    local result, hdrs = LrHttp.get(self.url .. self.apiBasePath .. apiPath, ImmichAPI:createHeaders())
    
    if not result then
        log:error('ImmichAPI GET request failed. ' .. apiPath)
        return false
    else
        log:trace('ImmichAPI GET request succeeded')
        local decoded = JSON:decode(result)
        return decoded
    end
end


function ImmichAPI:doMultiPartPostRequest(apiPath, mimeChunks)
    local result, hdrs = LrHttp.postMultipart(self.url .. self.apiBasePath .. apiPath, mimeChunks, ImmichAPI:createHeadersForMultipart())
    if not result then
        util.handleError('POST response headers: ' .. util.dumpTable(hdrs), "Error uploading some assets, please consult logs.")
        return nil
    else
        local parsedResult = JSON:decode(result)
        return parsedResult
    end
end

function ImmichAPI:doMultiPartPutRequest(apiPath, filePath, formData)
    log:trace('ImmichAPI: Preparing POST request ' .. apiPath)
    local url = self.url .. self.apiBasePath .. apiPath
    local boundary = 'FIXMEASTHISISSTATICFORNOWBUTSHOULDBERANDOM' -- TODO/FIXME
    
    local body = generateMultiPartBody(boundary, formData, filePath)
    local size = string.len(body)
    local reqhdrs = ImmichAPI:createHeadersForMultipartPut(boundary, size)
    
    log:trace('ImmichAPI multipart PUT headers:' .. util.dumpTable(reqhdrs))
    log:trace('ImmichAPI multipart PUT body:' .. body)


    local result, hdrs = LrHttp.post(url, body, reqhdrs, 'PUT', 15)
       
    if not result then
        log:error('ImmichAPI multipart PUT request failed. ' .. apiPath)
        log:error(util.dumpTable(hdrs))
        return false
    else
        log:trace('ImmichAPI multipart PUT request succeeded: ' .. result)
        local decoded = JSON:decode(result)
        return decoded
    end
end
