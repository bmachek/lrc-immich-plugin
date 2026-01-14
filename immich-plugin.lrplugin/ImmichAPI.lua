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
    log:trace('Immich reconfigured with URL: ' .. self.url)
    log:trace('Immich reconfigured with API key: ' .. util.cutApiKey(self.apiKey))
end

function ImmichAPI:setUrl(url)
    self.url = url
    log:trace('Immich new URL set: ' .. self.url)
end

function ImmichAPI:setApiKey(apiKey)
    self.apiKey = apiKey
    log:trace('Immich new API key set: ' .. util.cutApiKey(self.apiKey))
end

local function generateMultiPartBody(b, formData, filePath)
    local fileName = LrPathUtils.leafName(filePath)
    local body = ''
    local boundary = '--' .. b .. '\r\n'

    for i = 1, #formData do
        body = body .. boundary
        for k, v in pairs(formData[i]) do
            if k == 'name' then
                body = body .. 'Content-Disposition: form-data; name="' .. v .. '"\r\n\r\n'
            elseif k == 'value' then
                body = body .. v .. "\r\n"
            end
        end
    end

    local fh = io.open(filePath, "rb")
    local fileContent = ''
    if fh then
        fileContent = fh:read("*all")
    else
        log:error('Unable to open file: ' .. filePath)
    end

    -- log:trace(fileContent)

    body = body .. boundary
    body = body .. 'Content-Disposition: form-data; name="assetData"; filename="' .. fileName .. '"\r\n'
    body = body .. 'Content-Type: application/octet-stream\r\n\r\n'
    body = body .. fileContent
    body = body .. '\r\n--' .. b .. '--' .. '\r\n'

    return body
end

function ImmichAPI:downloadAsset(assetId)
    if util.nilOrEmpty(assetId) then
        util.handleError('downloadAsset: assetId empty', 'No asset ID provided. Check logs.')
        return nil
    end

    local assetUrl = string.format("%s%s/assets/%s/original", self.url, self.apiBasePath, assetId)
    log:trace("Downloading asset from URL: " .. assetUrl)

    local response, headers = LrHttp.get(assetUrl, ImmichAPI.createHeaders(self))

    if headers.status == 200 then
        log:trace("Asset downloaded successfully: " .. assetId)
        return response
    else
        log:error("Failed to download asset: " .. assetId)
        log:error("Response headers: " .. util.dumpTable(headers))
        if response ~= nil then
            log:error("Response body: " .. response)
        end
        return nil
    end
end

function ImmichAPI:hasLivePhotoVideo(assetId)
    if util.nilOrEmpty(assetId) then
        util.handleError('hasLivePhotoVideo: assetId empty', 'No asset ID provided. Check logs.')
        return nil
    end

    local path = '/assets/' .. assetId
    local parsedResponse = ImmichAPI.doGetRequest(self, path)

    if parsedResponse ~= nil and parsedResponse.livePhotoVideoId then
        log:trace("Asset has live photo video ID: " .. parsedResponse.livePhotoVideoId)
        return true
    else
        log:trace("Asset does not have a live photo video ID.")
        return false
    end
end

function ImmichAPI:getLivePhotoVideoId(assetId)
    if util.nilOrEmpty(assetId) then
        util.handleError('getLivePhotoVideoId: assetId empty', 'No asset ID provided. Check logs.')
        return nil
    end

    local path = '/assets/' .. assetId
    local parsedResponse = ImmichAPI.doGetRequest(self, path)

    if parsedResponse ~= nil and parsedResponse.livePhotoVideoId then
        log:trace("Live photo video ID: " .. parsedResponse.livePhotoVideoId)
        return parsedResponse.livePhotoVideoId
    else
        log:trace("No live photo video ID found.")
        return nil
    end
end

function ImmichAPI:getOriginalFileName(assetId)
    if util.nilOrEmpty(assetId) then
        util.handleError('getOriginalFileName: assetId empty', 'No asset ID provided. Check logs.')
        return nil
    end

    local path = '/assets/' .. assetId
    local parsedResponse = ImmichAPI.doGetRequest(self, path)

    if parsedResponse ~= nil and parsedResponse.originalFileName then
        log:trace("Original file name: " .. parsedResponse.originalFileName)
        return parsedResponse.originalFileName
    else
        log:trace("No original file name found.")
        return nil
    end
end



function ImmichAPI:getAlbumAssets(albumId)
    if util.nilOrEmpty(albumId) then
        util.handleError('getAlbumAssets: albumId empty', 'No album ID provided. Check logs.')
        return nil
    end

    local path = '/albums/' .. albumId
    local parsedResponse = ImmichAPI.doGetRequest(self, path)

    if not parsedResponse or not parsedResponse.assets then
        log:trace('getAlbumAssets: No assets found for album ID: ' .. albumId)
        return nil
    end

    local assets = {}
    for _, asset in ipairs(parsedResponse.assets) do
        table.insert(assets, {
            id = asset.id,
            originalFileName = asset.originalFileName,
        })
    end

    log:trace('getAlbumAssets: Retrieved ' .. #assets .. ' assets for album ID: ' .. albumId)
    return assets
end

-- Utility function to create headers
function ImmichAPI:createHeaders()
    return {
        { field = 'x-api-key',    value = self.apiKey },
        { field = 'Accept',       value = 'application/json' },
        { field = 'Content-Type', value = 'application/json' },
    }
end

function ImmichAPI:createHeadersForMultipart()
    return {
        { field = 'x-api-key', value = self.apiKey },
        { field = 'Accept',    value = 'application/json' },
    }
end

function ImmichAPI:createHeadersForMultipartPut(boundary, length)
    return {
        { field = 'x-api-key',      value = self.apiKey },
        { field = 'Accept',         value = 'application/json' },
        { field = 'Content-Type',   value = 'multipart/form-data;boundary="' .. boundary .. '"' },
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
    if self.url == '' or self.apiKey == '' then
        log:error('checkConnectivity: test failed. URL and API key empty.')
        return false
    end

    local requestHeaders = ImmichAPI.createHeaders(self)
    local response, headers = LrHttp.get(self.url .. self.apiBasePath .. '/users/me', requestHeaders)

    if headers.status == 200 then
        -- log:trace('checkConnectivity: test OK.')
        return true
    else
        log:error('checkConnectivity: test failed.')
        log:error('Response headers: ' .. util.dumpTable(headers))
        if response ~= nil then
            log:error('Response body: ' .. response)
        end
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
        { name = 'assetData',      filePath = filePath,        fileName = fileName, contentType = 'application/octet-stream' },
        { name = 'deviceAssetId',  value = localId },
        { name = 'deviceId',       value = self.deviceIdString },
        { name = 'fileCreatedAt',  value = submitDate },
        { name = 'fileModifiedAt', value = submitDate },
        { name = 'isFavorite',     value = 'false' }
    }

    local parsedResponse = ImmichAPI.doMultiPartPostRequest(self, apiPath, mimeChunks)
    if parsedResponse ~= nil then
        return parsedResponse.id
    end
    return nil
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

    local newImmichId = ImmichAPI:uploadAsset(pathOrMessage, localId)
    if newImmichId ~= nil then
        if ImmichAPI:copyAssetMetadata(immichId, newImmichId) then
            if ImmichAPI:deleteAsset(immichId) then
                log:trace('copyAssetMetadata: Successfully replaced asset ' .. immichId .. ' with new asset ' .. newImmichId)
                return newImmichId
            else
                util.handleError('copyAssetMetadata: Failed to delete old asset ' .. immichId,
                    'Failed to delete old asset after replacement. Check logs.')
                return newImmichId
            end
        else
            util.handleError('replaceAsset: Failed to copy metadata from old asset ' .. immichId .. ' to new asset ' .. newImmichId,
                'Failed to copy metadata to new asset after replacement. Check logs. New asset will be deleted.')
            ImmichAPI:deleteAsset(newImmichId)
            return nil
        end
    end
    return nil
end

function ImmichAPI:copyAssetMetadata(sourceAssetId, targetAssetId)
    if util.nilOrEmpty(sourceAssetId) then
        util.handleError('copyAssetMetadata: sourceAssetId empty', 'Source Immich asset ID missing. Check logs.')
        return nil
    end

    if util.nilOrEmpty(targetAssetId) then
        util.handleError('copyAssetMetadata: targetAssetId empty', 'Target Immich asset ID missing. Check logs.')
        return nil
    end

    local apiPath = '/assets/copy'
    local body = { sourceId = sourceAssetId, targetId = targetAssetId }

    local parsedResponse = ImmichAPI:doCustomRequest('PUT', apiPath, body)
    if parsedResponse ~= nil then
        return true
    end
    return false
end


function ImmichAPI:deleteAsset(immichId)
    if util.nilOrEmpty(immichId) then
        util.handleError('deleteAsset: immichId empty', 'Immich asset ID missing. Check logs.')
        return false
    end

    local apiPath = '/assets'

    local body = { ids = { immichId } }

    local parsedResponse = ImmichAPI:doCustomRequest('DELETE', apiPath, body)
    if parsedResponse ~= nil then
        return true
    end
    return false
end


function ImmichAPI:removeAssetFromAlbum(albumId, assetId)
    if util.nilOrEmpty(albumId) then
        util.handleError('removeAssetFromAlbum: albumId empty', 'Immich album ID missing. Check logs.')
        return false
    end

    if util.nilOrEmpty(assetId) then
        util.handleError('removeAssetFromAlbum: assetId empty', 'No Immich asset ID given. Check logs.')
        return false
    end

    local apiPath = '/albums/' .. albumId .. '/assets'
    local postBody = { ids = { assetId } }

    local parsedResponse = ImmichAPI.doCustomRequest(self, 'DELETE', apiPath, postBody)
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

    local parsedResponse = ImmichAPI.doCustomRequest(self, 'PUT', apiPath, postBody)
    if parsedResponse == nil then
        log:error("Unable to add asset (" .. assetId .. ") to album (" .. albumId .. ").")
        return false
    end

    return true
end

function ImmichAPI:createStack(assetIds)
    if not assetIds or #assetIds < 2 then
        util.handleError('createStack: need at least 2 assets', 'Need at least 2 assets to create a stack. Check logs.')
        return nil
    end

    local apiPath = '/stacks'
    local postBody = { assetIds = assetIds }

    log:trace('Creating stack with assets: ' .. JSON:encode(assetIds))
    
    local parsedResponse = ImmichAPI.doPostRequest(self, apiPath, postBody)
    if parsedResponse ~= nil then
        log:trace('Stack created successfully with ID: ' .. parsedResponse.id)
        return parsedResponse.id
    else
        log:error('Failed to create stack')
        return nil
    end
end

function ImmichAPI:createAlbum(albumName)
    if util.nilOrEmpty(albumName) then
        util.handleError('createAlbum: albumName empty', 'No album name given. Check logs.')
        return nil
    end

    local apiPath = '/albums'
    local postBody = { albumName = albumName }

    local parsedResponse = ImmichAPI.doPostRequest(self, apiPath, postBody)
    if parsedResponse ~= nil then
        return parsedResponse.id
    end
    return nil
end

function ImmichAPI:getAlbumNameById(albumId)
    if util.nilOrEmpty(albumId) then
        util.handleError('getAlbumNameById: albumId empty', 'No album ID given. Check logs.')
        return nil
    end

    local path = '/albums/' .. albumId
    local parsedResponse = ImmichAPI.doGetRequest(self, path)

    if parsedResponse ~= nil and parsedResponse.albumName then
        log:trace("Album name: " .. parsedResponse.albumName)
        return parsedResponse.albumName
    else
        log:trace("No album name found.")
        return nil
    end
end


function ImmichAPI:createOrGetAlbumFolderBased(albumName)
    if util.nilOrEmpty(albumName) then
        util.handleError('createAlbum: albumName empty', 'No album name given. Check logs.')
        return nil
    end

    local existingAlbums = ImmichAPI:getAlbumsByNameFolderBased(albumName)
    if existingAlbums ~= nil then
        if #existingAlbums > 0 then
            log:trace("Found existing folder based album with id: " .. existingAlbums[1].value)
            return existingAlbums[1].value
        end
    end

    local apiPath = '/albums'
    local postBody = { albumName = albumName, description = 'Based on Lightroom folder: ' .. albumName }

    local parsedResponse = ImmichAPI.doPostRequest(self, apiPath, postBody)
    if parsedResponse ~= nil then
        return parsedResponse.id
    end
    return nil
end

function ImmichAPI:deleteAlbum(albumId)
    local path = '/albums/' .. albumId

    local parsedResponse = ImmichAPI.doCustomRequest(self, 'DELETE', path, {})
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
    local path = '/albums'
    local parsedResponse = ImmichAPI.doGetRequest(self, path)
    local albums = {}
    if parsedResponse then
        for i = 1, #parsedResponse do
            local row = parsedResponse[i]
            table.insert(albums,
                { title = row.albumName .. ' (' .. string.sub(row.createdAt, 1, 19) .. ')', value = row.id })
        end
        return albums
    else
        return nil
    end
end

function ImmichAPI:getAlbumsWODate()
    local path = '/albums'
    local parsedResponse = ImmichAPI.doGetRequest(self, path)
    local albums = {}
    if parsedResponse then
        for i = 1, #parsedResponse do
            local row = parsedResponse[i]
            table.insert(albums,
                { title = row.albumName , value = row.id })
        end
        return albums
    else
        return nil
    end
end



function ImmichAPI:getAlbumsByNameFolderBased(albumName)
    local path = '/albums'
    local parsedResponse = ImmichAPI.doGetRequest(self, path)
    local albums = {}
    if parsedResponse then
        for i = 1, #parsedResponse do
            local row = parsedResponse[i]
            if row.albumName == albumName and row.description == 'Based on Lightroom folder: ' .. albumName then
                table.insert(albums,
                    { title = row.albumName .. ' (' .. string.sub(row.createdAt, 1, 19) .. ')', value = row.id })
            end
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

    local parsedResponse = ImmichAPI.doGetRequest(self, path)
    return parsedResponse
end

function ImmichAPI:checkIfAssetExists(localId, filename, dateCreated)
    local id = tostring(localId)

    local postBody = { deviceAssetId = id, deviceId = self.deviceIdString, isTrashed = false }
    local response = ImmichAPI.doPostRequest(self, '/search/metadata', postBody)

    if not response then
        log:trace('Asset with deviceAssetId ' .. id .. ' not found. No response')
        return nil
    elseif response.assets.count >= 1 then
        log:trace('Found existing asset with deviceAssetId ' .. tostring(localId))
        return response.assets.items[1].id, response.assets.items[1].deviceAssetId
    elseif dateCreated ~= nil and dateCreated ~= "" then
        log:trace('Asset with deviceAssetId ' .. id .. ' not found')

        postBody = { originalFileName = filename, takenAfter = dateCreated, takenBefore = dateCreated, isTrashed = false }
        response = ImmichAPI.doPostRequest(self, '/search/metadata', postBody)

        if not response then
            log:trace('No asset with originalFilename ' .. filename .. ' and creationDate ' .. dateCreated .. ' found')
            return nil
        elseif response.assets.count >= 1 then
            log:trace('Found existing asset with filename  ' .. filename .. ' and creationDate ' .. dateCreated)
            return response.assets.items[1].id, response.assets.items[1].deviceAssetId
        end
    end
    return nil
end

function ImmichAPI:checkIfAssetIsInAnAlbum(immichId)
    local postBody = { id = immichId, deviceId = self.deviceIdString, isNotInAlbum = true }
    local response = ImmichAPI.doPostRequest(self, '/search/metadata', postBody)

    if response ~= nil and type(response) == "table" then
        if response.assets.count == 1 and not response.assets.items[1].isTrashed then
            log:trace('checkIfAssetIsInAnAlbum: ' .. immichId .. ' is in NOT included in any album')
            return false
        end
    end

    log:trace('checkIfAssetIsInAnAlbum: ' .. immichId .. ' is included in at least one album')
    return true
end

function ImmichAPI:getLocalIdForAssetId(assetId)
    local parsedResponse = ImmichAPI.getAssetInfo(self, assetId)

    if parsedResponse ~= nil then
        return parsedResponse.deviceAssetId
    end

    return nil
end

function ImmichAPI:getAssetInfo(assetId)
    local path = '/assets/' .. assetId
    local parsedResponse = ImmichAPI.doGetRequest(self, path)
    return parsedResponse
end

function ImmichAPI:checkIfAlbumExists(albumId)
    if albumId == nil then
        return false
    end
    log:trace("ImmichAPI: checkIfAlbumExists")
    local albumInfo = ImmichAPI.doGetRequest(self, '/albums/' .. albumId)

    if albumInfo == nil then
        return false
    else
        return true
    end
end

function ImmichAPI:getAlbumInfo(albumId)
    log:trace("ImmichAPI: getAlbumInfo for: " .. albumId)
    local albumInfo = ImmichAPI.doGetRequest(self, '/albums/' .. albumId)
    return albumInfo
end

function ImmichAPI:getAlbumAssetIds(albumId)
    log:trace("ImmichAPI: getAlbumAssetIds for: " .. albumId)
    local albumInfo = ImmichAPI.doGetRequest(self, '/albums/' .. albumId)
    local assetIds = {}

    if albumInfo  ~= nil then
        if albumInfo.assets ~= nil then
            for i = 1, #albumInfo.assets do
                table.insert(assetIds, albumInfo.assets[i].id)
            end
        end
    end

    return assetIds
end

function ImmichAPI:doPostRequest(apiPath, postBody)
    if not ImmichAPI.checkConnectivity(self) then
        util.handleError('Immich connection not setup. Cannot perform POST request: ' .. apiPath,
            'Immich connection not setup. Go to module manager.')
        return nil
    end

    log:trace('ImmichAPI: Preparing POST request ' .. self.url .. self.apiBasePath .. apiPath)
    log:trace('ImmichAPI: ' .. util.cutApiKey(self.apiKey))
    if postBody ~= nil then
        log:trace('ImmichAPI: Postbody ' .. JSON:encode(postBody))
    end
    local response, headers = LrHttp.post(self.url .. self.apiBasePath .. apiPath, JSON:encode(postBody),
        ImmichAPI.createHeaders(self))

    if headers.status == 201 or headers.status == 200 then
        log:trace('ImmichAPI POST request succeeded: ' .. response)
        return JSON:decode(response)
    else
        ErrorHandler.handleError('ImmichAPI POST request failed. ' .. apiPath, util.dumpTable(headers))
        if response ~= nil then
            log:error('Response body: ' .. response)
        end
        return nil
    end
end

function ImmichAPI:doCustomRequest(method, apiPath, postBody)
    if not ImmichAPI.checkConnectivity(self) then
        util.handleError('Immich connection not setup. Cannot perform ' .. method .. ' request: ' .. apiPath,
            'Immich connection not setup. Go to module manager.')
        return nil
    end
    log:trace('ImmichAPI: Preparing ' .. method .. ' request ' .. self.url .. self.apiBasePath .. apiPath)
    log:trace('ImmichAPI: ' .. util.cutApiKey(self.apiKey))
    local url = self.url .. self.apiBasePath .. apiPath

    if postBody ~= nil then
        log:trace('ImmichAPI: Postbody ' .. JSON:encode(postBody))
    end

    local response, headers = LrHttp.post(url, JSON:encode(postBody), ImmichAPI.createHeaders(self), method, 5)

    if headers.status == 204 or headers.status == 201 or headers.status == 200 then
        log:trace('ImmichAPI ' .. method .. ' request succeeded: ' .. response)
        if util.nilOrEmpty(response) then
            return {}
        end
        return JSON:decode(response)
    else
        ErrorHandler.handleError('ImmichAPI ' .. method .. ' request failed. ' .. apiPath, util.dumpTable(headers))
        if response ~= nil then
            log:error('Response body: ' .. response)
        end
        return nil
    end
end

function ImmichAPI:doGetRequest(apiPath)
    if not ImmichAPI.checkConnectivity(self) then
        util.handleError('Immich connection not setup. Cannot perform GET request: ' .. apiPath,
            'Immich connection not setup. Go to module manager.')
        return nil
    end

    log:trace('ImmichAPI: Preparing GET request ' .. self.url .. self.apiBasePath .. apiPath)
    log:trace('ImmichAPI: ' .. util.cutApiKey(self.apiKey))
    local response, headers = LrHttp.get(self.url .. self.apiBasePath .. apiPath, ImmichAPI.createHeaders(self))

    if headers.status == 200 then
        log:trace('ImmichAPI GET request succeeded')
        return JSON:decode(response)
    else
        ErrorHandler.handleError('ImmichAPI GET request failed. ' .. apiPath, util.dumpTable(headers))
        if response ~= nil then
            log:trace('Response body: ' .. response)
        end
        return nil
    end
end

function ImmichAPI:doMultiPartPostRequest(apiPath, mimeChunks)
    if not ImmichAPI.checkConnectivity(self) then
        util.handleError('Immich connection not setup. Cannot perform multipart POST request: ' .. apiPath,
            'Immich connection not setup. Go to module manager.')
        return nil
    end

    log:trace('ImmichAPI: Preparing multipart POST request ' .. self.url .. self.apiBasePath .. apiPath)
    log:trace('ImmichAPI: ' .. util.cutApiKey(self.apiKey))

    local response, headers = LrHttp.postMultipart(self.url .. self.apiBasePath .. apiPath, mimeChunks,
        ImmichAPI.createHeadersForMultipart(self))

    if headers.status == 201 or headers.status == 200 then
        return JSON:decode(response)
    else
        ErrorHandler.handleError('ImmichAPI multipart POST request failed. ' .. apiPath, util.dumpTable(headers))
        if response ~= nil then
            log:error('Response body: ' .. response)
        end
        return nil
    end
end

function ImmichAPI:doMultiPartPutRequest(apiPath, filePath, formData)
    if not ImmichAPI.checkConnectivity(self) then
        util.handleError('Immich connection not setup. Cannot perform multipart PUT request: ' .. apiPath,
            'Immich connection not setup. Go to module manager.')
        return nil
    end

    log:trace('ImmichAPI: Preparing multipart PUT request ' .. self.url .. self.apiBasePath .. apiPath)
    log:trace('ImmichAPI: ' .. util.cutApiKey(self.apiKey))

    local url = self.url .. self.apiBasePath .. apiPath
    local boundary = 'FIXMEASTHISISSTATICFORNOWBUTSHOULDBERANDOM' -- TODO/FIXME

    local body = generateMultiPartBody(boundary, formData, filePath)
    local size = string.len(body)
    local reqhdrs = ImmichAPI.createHeadersForMultipartPut(self, boundary, size)

    log:trace('ImmichAPI multipart PUT headers:' .. util.dumpTable(reqhdrs))
    log:trace('ImmichAPI multipart PUT body:' .. body)


    local response, headers = LrHttp.post(url, body, reqhdrs, 'PUT', 15)

    log:trace('ImmichAPI multipart PUT response headers ' .. util.dumpTable(headers))

    if headers.status == 201 or headers.status == 200 then
        log:trace('ImmichAPI multipart PUT request succeeded: ' .. response)
        return JSON:decode(response)
    else
        ErrorHandler.handleError('ImmichAPI multipart PUT request failed. ' .. apiPath, util.dumpTable(headers))
        if response ~= nil then
            log:error('Response body: ' .. response)
        end
        return nil
    end
end
