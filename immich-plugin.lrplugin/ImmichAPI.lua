
ImmichAPI = {}
ImmichAPI.__index = ImmichAPI


function ImmichAPI:new(url, apiKey)
    local o = setmetatable({}, ImmichAPI)
    self.deviceIdString = 'Lightroom Immich Upload Plugin'
    self.apiBasePath = '/api'
    self.apiKey = apiKey
    self.url = url
    return o
end

function ImmichAPI:reconfigure(url, apiKey)
    self.apiKey = apiKey
    self.url = url
    log:trace('Immich reconfigured with ' .. self.url)
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
    if util.nilOrEmpty(url) then
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
    log:trace('ImmichAPI: Preparing GET request /users/me')

    if util.nilOrEmpty(self.url) or util.nilOrEmpty(self.apiKey) then
        log:error('checkConnectivity: test failed.')
        return false
    end

    local response, headers = LrHttp.get(self.url .. self.apiBasePath .. '/users/me', ImmichAPI:createHeaders())

    if headers.status == 200 then
        log:trace('checkConnectivity: test OK.')
        return true
    else
        log:error('checkConnectivity: test failed.')
        return false
    end
end

-- Thanks to Min Idzelis
function ImmichAPI:getAlbumUrl(albumId)
    if util.nilOrEmpty(albumId) then
        return nil
    end
    return self.url .. '/albums/' .. albumId
end

-- Thanks to Min Idzelis
function ImmichAPI:getAssetUrl(id)
    if util.nilOrEmpty(id) then
        return nil
    end
    return self.url .. '/photos/' .. id
end

function ImmichAPI:uploadAsset(pathOrMessage, localId)
    if util.nilOrEmpty(pathOrMessage) then
        util.handleError('uploadAsset: pathOrMessage empty', 'No filename given. Check logs.')
        return nil
    end

    if util.nilOrEmpty(localId) then
        util.handleError('uploadAsset: localId empty', 'Local catalog id missing. Check logs.')
        return nil
    end


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

    parsedResponse = ImmichAPI:doMultiPartPostRequest(apiPath, mimeChunks)
    return parsedResponse.id
end

function ImmichAPI:replaceAsset(immichId, pathOrMessage, localId)

    if util.nilOrEmpty(immichId) then
        util.handleError('replaceAsset: immichId empty', 'Immich asset ID missing. Check logs.')
        return nil
    end

    if util.nilOrEmpty(pathOrMessage) then
        util.handleError('replaceAsset: pathOrMessage empty', 'No filename given. Check logs.')
        return nil
    end

    if util.nilOrEmpty(localId) then
        util.handleError('replaceAsset: localId empty', 'Local catalog id missing. Check logs.')
        return nil
    end

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
    parsedResponse = ImmichAPI:doMultiPartPutRequest(apiPath, pathOrMessage, formData)
    return immichId
end

function ImmichAPI:removeAssetFromAlbum(albumId, assetId)

    
    if util.nilOrEmpty(albumId) then
        util.handleError('removeAssetFromAlbum: albumId empty', 'Immich album ID missing. Check logs.')
        return nil
    end

    if util.nilOrEmpty(assetId) then
        util.handleError('removeAssetFromAlbum: assetId empty', 'No Immich asset ID given. Check logs.')
        return nil
    end

    local apiPath = '/albums/' .. albumId .. '/assets'
    local postBody = { ids = { assetId } }

    local parsedResponse = ImmichAPI:doCustomRequest('DELETE', apiPath, postBody)
    if parsedResponse == nil then
        -- log:error("Unable to remove asset (" .. assetId .. ") from album (" .. albumId .. ").")
        return false
    end

    return true
end

function ImmichAPI:addAssetToAlbum(albumId, assetId)
        
    if util.nilOrEmpty(albumId) then
        util.handleError('addAssetToAlbum: albumId empty', 'Immich album ID missing. Check logs.')
        return nil
    end

    if util.nilOrEmpty(assetId) then
        util.handleError('addAssetToAlbum: assetId empty', 'No Immich asset ID given. Check logs.')
        return nil
    end

    local apiPath = '/albums/' .. albumId .. '/assets'
    local postBody = { ids = { assetId } }

    local parsedResponse = ImmichAPI:doCustomRequest('PUT', apiPath, postBody)
    if parsedResponse == nil then
        log:error("Unable to add asset (" .. assetId .. ") to album (" .. albumId .. ").")
        return false
    end

    return true
end

function ImmichAPI:createAlbum(albumName)
    if util.nilOrEmpty(albumName) then
        util.handleError('createAlbum: albumName empty', 'No album name given. Check logs.')
        return nil
    end

    local apiPath = '/albums'
    local postBody = { albumName = albumName }

    local parsedResponse = ImmichAPI:doPostRequest(apiPath, postBody)
    if parsedResponse == nil then 
        return nil
    else 
        return parsedResponse.id
    end
end

function ImmichAPI:deleteAlbum(albumId)
    local path = '/albums/' .. albumId

    local parsedResponse = ImmichAPI:doCustomRequest('DELETE', path, {})
    if parsedResponse == nil then
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

    local parsedResponse = ImmichAPI:doCustomRequest('PATCH', path, postBody)
    if parsedResponse == nil then
        util.handleError("Unable to rename album (" .. albumId .. ").", "Error renaming album, please consult logs.")
        return false
    else
        return true
    end
end

function ImmichAPI:getAlbums()

    local path =  '/albums'
    local parsedResponse = ImmichAPI:doGetRequest(path)
    local albums = {}
    if parsedResponse then
        for i = 1, #parsedResponse do
            local row = parsedResponse[i]
            table.insert(albums, { title = row.albumName .. ' (' .. string.sub(row.createdAt, 1, 19) .. ')', value = row.id })
        end
        return albums
    else 
        return nil
    end    
end

function ImmichAPI:getActivities(albumId, assetId)
    local path = '/activities?albumId=' .. albumId

    if assetId then
        path = path .. '&assetId=' .. assetId
    end

    local parsedResponse = ImmichAPI:doGetRequest(path)
    return parsedResponse
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

function ImmichAPI:getLocalIdForAssetId(assetId)
    local parsedResponse = ImmichAPI:getAssetInfo(assetId)

    if not parsedResponse == nil then
        return parsedResponse.deviceAssetId
    end

    return nil
end


function ImmichAPI:getAssetInfo(assetId)
    path = '/assets/' .. assetId
    local parsedResponse = ImmichAPI:doGetRequest(path)
    return parsedResponse
end

function ImmichAPI:checkIfAlbumExists(albumId)
    if albumId == nil then
        return false
    end 
    log:trace("ImmichAPI: checkIfAlbumExists")
    local albumInfo = ImmichAPI:doGetRequest('/albums/' .. albumId)

    if albumInfo == nil then 
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
    if not ImmichAPI:checkConnectivity() then 
        util.handleError('Immich connection not setup. Cannot perform POST request: ' .. apiPath, 'Immich connection not setup. Go to module manager.')
        return nil
    end

    log:trace('ImmichAPI: Preparing POST request ' .. apiPath)
    if not postBody == nil then
        log:trace('ImmichAPI: Postbody ' .. JSON:encode(postBody))
    end
    local response, headers = LrHttp.post(self.url .. self.apiBasePath .. apiPath, JSON:encode(postBody), ImmichAPI:createHeaders())
    
    if headers.status == 201 or headers.status == 200 then
        log:trace('ImmichAPI POST request succeeded: ' .. response)
        return JSON:decode(response)
    else
        log:error('ImmichAPI POST request failed. ' .. apiPath)
        log:error(util.dumpTable(headers))
        log:error(response)
        return nil
    end
end

function ImmichAPI:doCustomRequest(method, apiPath, postBody)
    if not ImmichAPI:checkConnectivity() then 
        util.handleError('Immich connection not setup. Cannot perform ' .. method .. ' request: ' .. apiPath, 'Immich connection not setup. Go to module manager.')
        return nil
    end
    log:trace('ImmichAPI: Preparing ' .. method .. ' request ' .. apiPath)
    local url = self.url .. self.apiBasePath .. apiPath

    if not postBody == nil then
        log:trace('ImmichAPI: Postbody ' .. JSON:encode(postBody))
    end

    local response, headers = LrHttp.post(url, JSON:encode(postBody), ImmichAPI:createHeaders(), method, 5)

    if headers.status == 201 or headers.status == 200 then
        log:trace('ImmichAPI ' .. method .. ' request succeeded: ' .. response)
        if util.nilOrEmpty(response) then
            return {}
        end
        return JSON:decode(response)
    else
        log:error('ImmichAPI ' .. method .. ' request failed. ' .. apiPath)
        log:error(util.dumpTable(headers))
        log:error(response)
        return nil
    end
end

function ImmichAPI:doGetRequest(apiPath)
    if not ImmichAPI:checkConnectivity() then 
        util.handleError('Immich connection not setup. Cannot perform GET request: ' .. apiPath, 'Immich connection not setup. Go to module manager.')
        return nil
    end

    log:trace('ImmichAPI: Preparing GET request ' .. apiPath)
    local response, headers = LrHttp.get(self.url .. self.apiBasePath .. apiPath, ImmichAPI:createHeaders())

    if headers.status == 200 then
        log:trace('ImmichAPI GET request succeeded')
        return JSON:decode(response)
    else
        log:error('ImmichAPI GET request failed. ' .. apiPath)
        log:error(util.dumpTable(headers))
        log:error(response)
        return nil
    end
end


function ImmichAPI:doMultiPartPostRequest(apiPath, mimeChunks)
    if not ImmichAPI:checkConnectivity() then 
        util.handleError('Immich connection not setup. Cannot perform multipart POST request: ' .. apiPath, 'Immich connection not setup. Go to module manager.')
        return nil
    end
    
    local response, headers = LrHttp.postMultipart(self.url .. self.apiBasePath .. apiPath, mimeChunks, ImmichAPI:createHeadersForMultipart())

    if headers.status == 201 or headers.status == 200 then
        return JSON:decode(response)
    else
        log:error('ImmichAPI multipart POST request failed. ' .. apiPath)
        log:error(util.dumpTable(headers))
        log:error(response)
        return nil
    end
end

function ImmichAPI:doMultiPartPutRequest(apiPath, filePath, formData)
    if not ImmichAPI:checkConnectivity() then 
        util.handleError('Immich connection not setup. Cannot perform multipart PUT request: ' .. apiPath, 'Immich connection not setup. Go to module manager.')
        return nil
    end

    log:trace('ImmichAPI: Preparing POST request ' .. apiPath)
    local url = self.url .. self.apiBasePath .. apiPath
    local boundary = 'FIXMEASTHISISSTATICFORNOWBUTSHOULDBERANDOM' -- TODO/FIXME
    
    local body = generateMultiPartBody(boundary, formData, filePath)
    local size = string.len(body)
    local reqhdrs = ImmichAPI:createHeadersForMultipartPut(boundary, size)
    
    log:trace('ImmichAPI multipart PUT headers:' .. util.dumpTable(reqhdrs))
    log:trace('ImmichAPI multipart PUT body:' .. body)


    local response, headers = LrHttp.post(url, body, reqhdrs, 'PUT', 15)
    
    log:trace('ImmichAPI multipart PUT response headers ' .. util.dumpTable(headers))

    if headers.status == 201 or headers.status == 200  then
        log:trace('ImmichAPI multipart PUT request succeeded: ' .. response)
        return JSON:decode(response)
    else
        log:error('ImmichAPI multipart PUT request failed. ' .. apiPath)
        log:error(util.dumpTable(headers))
        log:error(response)
        return nil
    end
end

function ImmichAPI.immichConnected()
    if immich == nil then
        return false
    elseif immich:checkConnectivity() then
        return true
    else 
        return false
    end
end

-- Global instance of connection to immich.
_G.immich = ImmichAPI:new(prefs.url, prefs.apiKey)