--[[
    ImmichAPI – Lua client for Immich server API.
    Handles connectivity, assets, albums, stacks, and HTTP request/response.
]]

-- Constants
local API_BASE_PATH = '/api'
local HTTP_TIMEOUT_DEFAULT = 5
local HTTP_TIMEOUT_UPLOAD = 15
local DEVICE_ID_STRING = 'Lightroom Immich Upload Plugin'

local SUCCESS_STATUS_GET = 200
local SUCCESS_STATUS_POST = { [200] = true, [201] = true }
local SUCCESS_STATUS_CUSTOM = { [200] = true, [201] = true, [204] = true }

ImmichAPI = {}
ImmichAPI.__index = ImmichAPI

-- ---------------------------------------------------------------------------
-- Private helpers
-- ---------------------------------------------------------------------------

local function safeDecodeJson(response, context)
    local ok, decoded = pcall(function() return JSON:decode(response or "{}") end)
    if not ok or decoded == nil then
        log:error('ImmichAPI ' .. context .. ': JSON decode failed: ' .. tostring(decoded))
        return nil
    end
    return decoded
end

local function ensureConnectivity(api)
    if not api:checkConnectivity() then
        util.handleError('Immich connection not setup.', 'Immich connection not setup. Go to module manager.')
        return false
    end
    return true
end

local function logRequestStart(api, method, apiPath)
    log:trace('ImmichAPI: Preparing ' .. method .. ' request ' .. api.url .. api.apiBasePath .. apiPath)
    log:trace('ImmichAPI: ' .. util.cutApiKey(api.apiKey))
end

local function handleRequestFailure(method, apiPath, status, headers, response)
    local detail = (headers and util.dumpTable(headers)) or "No headers"
    ErrorHandler.handleError(
        'ImmichAPI ' .. tostring(method) .. ' request failed. ' .. apiPath .. ' (status ' .. tostring(status or '?') .. ')',
        detail
    )
    if response ~= nil then
        log:error('Response body: ' .. tostring(response))
    end
end

local function generateBoundary()
    return "ImmichUpload" .. tostring(math.random(100000, 999999))
end

local function generateMultiPartBody(boundary, formData, filePath)
    if not boundary or not formData or not filePath or type(filePath) ~= "string" then
        log:error('generateMultiPartBody: invalid arguments (boundary, formData or filePath missing)')
        return nil
    end
    local fileName = LrPathUtils.leafName(filePath)
    local body = ''
    local boundaryLine = '--' .. boundary .. '\r\n'

    for i = 1, #formData do
        local part = formData[i]
        local name = part and part.name
        local value = part and part.value
        if name then
            body = body .. boundaryLine
            body = body .. 'Content-Disposition: form-data; name="' .. name .. '"\r\n\r\n'
            body = body .. tostring(value or '') .. "\r\n"
        end
    end

    local fh = io.open(filePath, "rb")
    if not fh then
        log:error('generateMultiPartBody: unable to open file: ' .. tostring(filePath))
        return nil
    end
    local fileContent = fh:read("*all")
    fh:close()
    if not fileContent then
        log:error('generateMultiPartBody: failed to read file: ' .. filePath)
        return nil
    end

    body = body .. boundaryLine
    body = body .. 'Content-Disposition: form-data; name="assetData"; filename="' .. fileName .. '"\r\n'
    body = body .. 'Content-Type: application/octet-stream\r\n\r\n'
    body = body .. fileContent
    body = body .. '\r\n--' .. boundary .. '--\r\n'

    return body
end

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

function ImmichAPI:new(url, apiKey)
    local o = setmetatable({}, ImmichAPI)
    o.deviceIdString = DEVICE_ID_STRING
    o.apiBasePath = API_BASE_PATH
    o.apiKey = (apiKey ~= nil and type(apiKey) == "string") and apiKey or ""
    o.url = (url ~= nil and type(url) == "string") and url or ""
    return o
end

function ImmichAPI:reconfigure(url, apiKey)
    self.apiKey = (apiKey ~= nil and type(apiKey) == "string") and apiKey or self.apiKey or ""
    self.url = (url ~= nil and type(url) == "string") and url or self.url or ""
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

-- ---------------------------------------------------------------------------
-- Assets
-- ---------------------------------------------------------------------------

function ImmichAPI:downloadAsset(assetId)
    if util.nilOrEmpty(assetId) then
        util.handleError('downloadAsset: assetId empty', 'No asset ID provided. Check logs.')
        return nil
    end

    local assetUrl = string.format("%s%s/assets/%s/original", self.url, self.apiBasePath, assetId)
    log:trace("Downloading asset from URL: " .. assetUrl)

    local response, headers = LrHttp.get(assetUrl, self:createHeaders())

    if not headers then
        log:error("downloadAsset: no response headers (network or server error) for asset " .. tostring(assetId))
        util.handleError('downloadAsset: no response from server', 'Could not download asset. Check connection and Immich URL.')
        return nil
    end
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
    local parsedResponse = self:doGetRequest(path)

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
    local parsedResponse = self:doGetRequest(path)

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
    local parsedResponse = self:doGetRequest(path)

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
    local parsedResponse = self:doGetRequest(path)

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

-- ---------------------------------------------------------------------------
-- Headers
-- ---------------------------------------------------------------------------

local function safeApiKey(api)
    return (api and api.apiKey ~= nil and type(api.apiKey) == "string") and api.apiKey or ""
end

function ImmichAPI:createHeaders()
    return {
        { field = 'x-api-key',    value = safeApiKey(self) },
        { field = 'Accept',       value = 'application/json' },
        { field = 'Content-Type', value = 'application/json' },
    }
end

function ImmichAPI:createHeadersForMultipart()
    return {
        { field = 'x-api-key', value = safeApiKey(self) },
        { field = 'Accept',    value = 'application/json' },
    }
end

function ImmichAPI:createHeadersForMultipartPut(boundary, length)
    return {
        { field = 'x-api-key',      value = safeApiKey(self) },
        { field = 'Accept',         value = 'application/json' },
        { field = 'Content-Type',   value = 'multipart/form-data; boundary="' .. boundary .. '"' },
        { field = 'Content-Length', value = tostring(length) },
    }
end

-- Returns fixed URL on success; nil or false on failure. Caller must assign: url = api:sanityCheckAndFixURL(url)
function ImmichAPI:sanityCheckAndFixURL(url)
    if util.nilOrEmpty(url) then
        util.handleError('sanityCheckAndFixURL: URL is empty', "Error: Immich server URL is empty.")
        return false
    end
    if not string.match(url, "^https?://") then
        util.handleError('sanityCheckAndFixURL: URL is missing protocol (http:// or https://).', 'Please enter a valid URL starting with http:// or https://')
        return nil
    end
    local sanitized = string.match(url, "^https?://[%w%.%-]+[:%d]*")
    if not sanitized then
        util.handleError('sanityCheckAndFixURL: invalid URL format.', 'Please enter a valid Immich server URL.')
        return nil
    end
    if string.len(sanitized) < string.len(url) then
        log:trace('sanityCheckAndFixURL: removed trailing path from URL.')
    end
    return sanitized
end

function ImmichAPI:checkConnectivity()
    if util.nilOrEmpty(self.url) or util.nilOrEmpty(self.apiKey) then
        log:error('checkConnectivity: URL or API key is empty. Configure in plugin settings.')
        return false
    end

    local response, headers = LrHttp.get(self.url .. self.apiBasePath .. '/users/me', self:createHeaders())

    if not headers then
        log:error('checkConnectivity: no response headers (network error or invalid URL)')
        return false
    end
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

-- ---------------------------------------------------------------------------
-- Dialog helpers (URL validation and test connection for Publish/Export dialogs)
-- ---------------------------------------------------------------------------

local function _trimString(s)
	if type(s) ~= "string" then return "" end
	return s:match("^%s*(.-)%s*$") or ""
end

-- Validates URL for Lr edit_field validate callback. Does not rely on an existing API instance.
-- url: value from the field; baseUrl, baseApiKey: current propertyTable values (for temp instance).
-- Returns: valid (bool), newValue (string), errorMessage (string).
function ImmichAPI.validateUrlForDialog(url, baseUrl, baseApiKey)
	local raw = (type(url) == "string") and url or ""
	local trimmed = _trimString(raw)
	if trimmed == "" then
		return false, url, "URL must not be empty. Example: https://demo.immich.app"
	end
	local api = ImmichAPI:new(baseUrl or "", baseApiKey or "")
	local result = api:sanityCheckAndFixURL(trimmed)
	if result == false then
		return false, url, "URL must not be empty. Example: https://demo.immich.app"
	end
	if result == nil then
		return false, url, "Invalid URL format. Example: https://demo.immich.app"
	end
	if result == trimmed then
		return true, trimmed, ""
	end
	if LrDialogs and LrDialogs.message then
		LrDialogs.message("URL was autocorrected to: " .. result)
	end
	return true, result, ""
end

-- Runs a connection test. Trims url and apiKey; uses existingApi if provided and reconfigures it.
-- Returns: success (bool), message (string), apiInstance (for propertyTable.immich).
function ImmichAPI.testConnection(url, apiKey, existingApi)
	local u = _trimString(type(url) == "string" and url or "")
	local key = (type(apiKey) == "string") and apiKey or ""
	if u == "" or key == "" then
		return false, "Please enter URL and API key first.", nil
	end
	local api = existingApi
	if api and type(api.reconfigure) == "function" then
		api:reconfigure(u, key)
	else
		api = ImmichAPI:new(u, key)
	end
	if api:checkConnectivity() then
		return true, "Connection test successful", api
	end
	return false, "Connection test failed. Check URL, API key, and network.", api
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

function ImmichAPI:uploadAsset(pathOrMessage, deviceAssetId)
    if util.nilOrEmpty(pathOrMessage) then
        util.handleError('uploadAsset: pathOrMessage empty', 'No filename given. Check logs.')
        return nil
    end

    if util.nilOrEmpty(deviceAssetId) then
        util.handleError('uploadAsset: deviceAssetId empty', 'Device asset ID missing. Check logs.')
        return nil
    end


    local apiPath = '/assets'
    local submitDate = LrDate.timeToIsoDate(LrDate.currentTime())
    local filePath = pathOrMessage
    local fileName = LrPathUtils.leafName(filePath)

    local mimeChunks = {
        { name = 'assetData',      filePath = filePath,        fileName = fileName, contentType = 'application/octet-stream' },
        { name = 'deviceAssetId',  value = tostring(deviceAssetId) },
        { name = 'deviceId',       value = self.deviceIdString },
        { name = 'fileCreatedAt',  value = submitDate },
        { name = 'fileModifiedAt', value = submitDate },
        { name = 'isFavorite',     value = 'false' }
    }

    local parsedResponse = self:doMultiPartPostRequest(apiPath, mimeChunks)
    if parsedResponse ~= nil then
        return parsedResponse.id
    end
    return nil
end

function ImmichAPI:replaceAsset(immichId, pathOrMessage, deviceAssetId)
    if util.nilOrEmpty(immichId) then
        util.handleError('replaceAsset: immichId empty', 'Immich asset ID missing. Check logs.')
        return nil
    end

    if util.nilOrEmpty(pathOrMessage) then
        util.handleError('replaceAsset: pathOrMessage empty', 'No filename given. Check logs.')
        return nil
    end

    if util.nilOrEmpty(deviceAssetId) then
        util.handleError('replaceAsset: deviceAssetId empty', 'Device asset ID missing. Check logs.')
        return nil
    end

    local newImmichId = self:uploadAsset(pathOrMessage, deviceAssetId)
    if newImmichId ~= nil then
        -- Immich may return the existing asset ID (e.g. duplicate detection); skip replace steps
        if newImmichId == immichId then
            log:trace('replaceAsset: Upload returned same ID, no replace needed: ' .. immichId)
            return immichId
        end
        if self:copyAssetMetadata(immichId, newImmichId) then
            if self:deleteAsset(immichId) then
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
            self:deleteAsset(newImmichId)
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

    local parsedResponse = self:doCustomRequest('PUT', apiPath, body)
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

    local parsedResponse = self:doCustomRequest('DELETE', apiPath, body)
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

    local parsedResponse = self:doCustomRequest('DELETE', apiPath, postBody)
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

    local parsedResponse = self:doCustomRequest('PUT', apiPath, postBody)
    if parsedResponse == nil then
        log:error("Unable to add asset (" .. assetId .. ") to album (" .. albumId .. ").")
        return false
    end

    return true
end

-- ---------------------------------------------------------------------------
-- Stacks
-- ---------------------------------------------------------------------------

function ImmichAPI:createStack(assetIds)
    if not assetIds or #assetIds < 2 then
        util.handleError('createStack: need at least 2 assets', 'Need at least 2 assets to create a stack. Check logs.')
        return nil
    end

    local apiPath = '/stacks'
    local postBody = { assetIds = assetIds }

    log:trace('Creating stack with assets: ' .. JSON:encode(assetIds))
    
    local parsedResponse = self:doPostRequest(apiPath, postBody)
    if parsedResponse ~= nil then
        log:trace('Stack created successfully with ID: ' .. parsedResponse.id)
        return parsedResponse.id
    else
        log:error('Failed to create stack')
        return nil
    end
end

-- ---------------------------------------------------------------------------
-- Albums
-- ---------------------------------------------------------------------------

function ImmichAPI:createAlbum(albumName)
    if util.nilOrEmpty(albumName) then
        util.handleError('createAlbum: albumName empty', 'No album name given. Check logs.')
        return nil
    end

    local apiPath = '/albums'
    local postBody = { albumName = albumName }

    local parsedResponse = self:doPostRequest(apiPath, postBody)
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
    local parsedResponse = self:doGetRequest(path)

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

    local existingAlbums = self:getAlbumsByNameFolderBased(albumName)
    if existingAlbums ~= nil then
        if #existingAlbums > 0 then
            log:trace("Found existing folder based album with id: " .. existingAlbums[1].value)
            return existingAlbums[1].value
        end
    end

    local apiPath = '/albums'
    local postBody = { albumName = albumName, description = 'Based on Lightroom folder: ' .. albumName }

    local parsedResponse = self:doPostRequest( apiPath, postBody)
    if parsedResponse ~= nil then
        return parsedResponse.id
    end
    return nil
end

function ImmichAPI:deleteAlbum(albumId)
    if util.nilOrEmpty(albumId) then
        util.handleError('deleteAlbum: albumId empty', 'No album ID provided. Cannot delete album.')
        return false
    end
    local path = '/albums/' .. albumId

    local parsedResponse = self:doCustomRequest('DELETE', path, {})
    if parsedResponse == nil then
        util.handleError("Unable to delete album (" .. albumId .. ").", "Error deleting album, please consult logs.")
        return false
    else
        return true
    end
end

function ImmichAPI:renameAlbum(albumId, newName)
    if util.nilOrEmpty(albumId) then
        util.handleError('renameAlbum: albumId empty', 'No album ID provided. Cannot rename album.')
        return false
    end
    if util.nilOrEmpty(newName) then
        util.handleError('renameAlbum: newName empty', 'No new name provided. Cannot rename album.')
        return false
    end
    local path = '/albums/' .. albumId

    local postBody = {}
    postBody.albumName = newName

    local parsedResponse = self:doCustomRequest('PATCH', path, postBody)
    if parsedResponse == nil then
        util.handleError("Unable to rename album (" .. tostring(albumId) .. ").", "Error renaming album, please consult logs.")
        return false
    else
        return true
    end
end

function ImmichAPI:getAlbums()
    local path = '/albums'
    local parsedResponse = self:doGetRequest(path)
    local albums = {}
    if parsedResponse and type(parsedResponse) == "table" then
        for i = 1, #parsedResponse do
            local row = parsedResponse[i]
            if row and row.id and row.albumName then
                local createdAt = (row.createdAt and type(row.createdAt) == "string") and string.sub(row.createdAt, 1, 19) or ""
                table.insert(albums,
                    { title = row.albumName .. ' (' .. createdAt .. ')', value = row.id })
            end
        end
        return albums
    else
        return nil
    end
end

function ImmichAPI:getAlbumsWODate()
    local path = '/albums'
    local parsedResponse = self:doGetRequest(path)
    local albums = {}
    if parsedResponse and type(parsedResponse) == "table" then
        for i = 1, #parsedResponse do
            local row = parsedResponse[i]
            if row and row.id and row.albumName then
                table.insert(albums, { title = row.albumName, value = row.id })
            end
        end
        return albums
    else
        return nil
    end
end



function ImmichAPI:getAlbumsByNameFolderBased(albumName)
    if util.nilOrEmpty(albumName) then
        return nil
    end
    local path = '/albums'
    local parsedResponse = self:doGetRequest(path)
    local albums = {}
    if parsedResponse and type(parsedResponse) == "table" then
        for i = 1, #parsedResponse do
            local row = parsedResponse[i]
            if row and row.id and row.albumName and row.albumName == albumName and
               (row.description or "") == ('Based on Lightroom folder: ' .. albumName) then
                local createdAt = (row.createdAt and type(row.createdAt) == "string") and string.sub(row.createdAt, 1, 19) or ""
                table.insert(albums, { title = row.albumName .. ' (' .. createdAt .. ')', value = row.id })
            end
        end
        return albums
    else
        return nil
    end
end

-- ---------------------------------------------------------------------------
-- Search / bulk
-- ---------------------------------------------------------------------------

function ImmichAPI:getActivities(albumId, assetId)
    if util.nilOrEmpty(albumId) then
        log:warn('getActivities: albumId empty')
        return nil
    end
    local path = '/activities?albumId=' .. tostring(albumId)

    if assetId and assetId ~= '' then
        path = path .. '&assetId=' .. tostring(assetId)
    end

    local parsedResponse = self:doGetRequest(path)
    return parsedResponse
end

-- Bulk check if assets exist by deviceAssetIds
-- Returns a map of deviceAssetId -> {id, deviceAssetId} for existing assets
-- This uses the /assets/existing endpoint which returns asset IDs that match the provided deviceAssetIds
function ImmichAPI:bulkCheckAssets(deviceAssetIds)
    if not deviceAssetIds or #deviceAssetIds == 0 then
        return {}
    end

    local postBody = {
        deviceAssetIds = deviceAssetIds,
        deviceId = self.deviceIdString
    }
    
    local response = self:doPostRequest( '/assets/existing', postBody)
    
    if not response or not response.existingIds then
        log:trace('bulkCheckAssets: No response or invalid response')
        return {}
    end
    
    -- Build a map for quick lookup
    -- The endpoint returns asset IDs, we need to get their deviceAssetIds to map back
    local existingMap = {}
    for _, assetId in ipairs(response.existingIds) do
        -- Get asset info to retrieve deviceAssetId
        local assetInfo = self:getAssetInfo(assetId)
        if assetInfo and assetInfo.deviceAssetId then
            existingMap[assetInfo.deviceAssetId] = {
                id = assetId,
                deviceAssetId = assetInfo.deviceAssetId
            }
        end
    end
    
    log:trace('bulkCheckAssets: Found ' .. #response.existingIds .. ' existing assets out of ' .. #deviceAssetIds .. ' checked')
    return existingMap
end

-- Enhanced duplicate detection that checks metadata first, then bulk check, then individual check
-- Returns assetId, deviceAssetId if found, nil otherwise
-- Backward compatible: also searches by localIdentifier so existing installations (uploaded with localIdentifier) are found
function ImmichAPI:checkIfAssetExistsEnhanced(photo, deviceAssetId, filename, dateCreated)
    require "MetadataTask"
    
    -- Step 1: Check metadata extension first (fastest, most reliable)
    local storedAssetId = MetadataTask.getImmichAssetId(photo)
    if storedAssetId and storedAssetId ~= "" then
        -- Verify the asset still exists in Immich
        local assetInfo = self:getAssetInfo(storedAssetId)
        if assetInfo and not assetInfo.isTrashed then
            log:trace('checkIfAssetExistsEnhanced: Found assetId in metadata: ' .. storedAssetId)
            return storedAssetId, assetInfo.deviceAssetId or deviceAssetId
        else
            -- Asset was deleted in Immich, clear metadata
            log:trace('checkIfAssetExistsEnhanced: Stored assetId ' .. storedAssetId .. ' no longer exists, clearing metadata')
            MetadataTask.setImmichAssetId(photo, nil)
        end
    end
    
    local function searchByDeviceAssetId(deviceId)
        if not deviceId or deviceId == "" then return nil, nil end
        local postBody = { deviceAssetId = tostring(deviceId), deviceId = self.deviceIdString, isTrashed = false }
        local response = self:doPostRequest('/search/metadata', postBody)
        if response and response.assets and response.assets.count >= 1 then
            return response.assets.items[1].id, response.assets.items[1].deviceAssetId
        end
        return nil, nil
    end
    
    -- Step 2: Check by current deviceAssetId (UUID or localIdentifier)
    local id = tostring(deviceAssetId)
    local foundId, foundDeviceId = searchByDeviceAssetId(id)
    if foundId then
        log:trace('checkIfAssetExistsEnhanced: Found existing asset with deviceAssetId ' .. id)
        MetadataTask.setImmichAssetId(photo, foundId)
        return foundId, foundDeviceId
    end
    
    -- Step 2b: Existing installations: assets were uploaded with localIdentifier as deviceAssetId.
    -- If we're now using UUID (different from localIdentifier), also search by localIdentifier.
    local localId = (photo and photo.localIdentifier) and tostring(photo.localIdentifier) or nil
    if localId and localId ~= id then
        foundId, foundDeviceId = searchByDeviceAssetId(localId)
        if foundId then
            log:trace('checkIfAssetExistsEnhanced: Found existing asset with localIdentifier (legacy): ' .. localId)
            MetadataTask.setImmichAssetId(photo, foundId)
            -- Return Immich's deviceAssetId so replaceAsset uses the same value
            return foundId, foundDeviceId
        end
    end
    
    -- Step 3: Fallback to filename + dateCreated search (for backward compatibility)
    if dateCreated ~= nil and dateCreated ~= "" then
        log:trace('checkIfAssetExistsEnhanced: deviceAssetId not found, trying filename + date')
        local postBody = { originalFileName = filename, takenAfter = dateCreated, takenBefore = dateCreated, isTrashed = false }
        local response = self:doPostRequest('/search/metadata', postBody)

        if response and response.assets and response.assets.count >= 1 then
            local foundId = response.assets.items[1].id
            local foundDeviceId = response.assets.items[1].deviceAssetId
            log:trace('checkIfAssetExistsEnhanced: Found existing asset with filename ' .. filename .. ' and creationDate ' .. dateCreated)
            MetadataTask.setImmichAssetId(photo, foundId)
            return foundId, foundDeviceId
        end
    end
    
    return nil
end

function ImmichAPI:checkIfAssetExists(localId, filename, dateCreated)
    if util.nilOrEmpty(localId) then
        log:warn('checkIfAssetExists: localId empty')
        return nil
    end
    local id = tostring(localId)

    local postBody = { deviceAssetId = id, deviceId = self.deviceIdString, isTrashed = false }
    local response = self:doPostRequest('/search/metadata', postBody)

    if not response or not response.assets then
        log:trace('Asset with deviceAssetId ' .. id .. ' not found. No response or invalid response')
        return nil
    elseif (response.assets.count or 0) >= 1 and response.assets.items and response.assets.items[1] then
        log:trace('Found existing asset with deviceAssetId ' .. tostring(localId))
        return response.assets.items[1].id, response.assets.items[1].deviceAssetId
    elseif dateCreated ~= nil and dateCreated ~= "" then
        log:trace('Asset with deviceAssetId ' .. id .. ' not found')

        postBody = { originalFileName = filename, takenAfter = dateCreated, takenBefore = dateCreated, isTrashed = false }
        response = self:doPostRequest('/search/metadata', postBody)

        if not response or not response.assets then
            log:trace('No asset with originalFilename ' .. tostring(filename) .. ' and creationDate ' .. tostring(dateCreated) .. ' found')
            return nil
        elseif (response.assets.count or 0) >= 1 and response.assets.items and response.assets.items[1] then
            log:trace('Found existing asset with filename ' .. tostring(filename) .. ' and creationDate ' .. tostring(dateCreated))
            return response.assets.items[1].id, response.assets.items[1].deviceAssetId
        end
    end
    return nil
end

function ImmichAPI:checkIfAssetIsInAnAlbum(immichId)
    if util.nilOrEmpty(immichId) then
        log:warn('checkIfAssetIsInAnAlbum: immichId empty')
        return false
    end
    local postBody = { id = immichId, deviceId = self.deviceIdString, isNotInAlbum = true }
    local response = self:doPostRequest('/search/metadata', postBody)

    if response and type(response) == "table" and response.assets then
        local count = response.assets.count or 0
        local items = response.assets.items or {}
        if count == 1 and items[1] and not items[1].isTrashed then
            log:trace('checkIfAssetIsInAnAlbum: ' .. tostring(immichId) .. ' is NOT included in any album')
            return false
        end
    end

    log:trace('checkIfAssetIsInAnAlbum: ' .. tostring(immichId) .. ' is included in at least one album')
    return true
end

function ImmichAPI:getLocalIdForAssetId(assetId)
    local parsedResponse = self:getAssetInfo(assetId)

    if parsedResponse ~= nil then
        return parsedResponse.deviceAssetId
    end

    return nil
end

function ImmichAPI:getAssetInfo(assetId)
    if util.nilOrEmpty(assetId) then
        log:warn('getAssetInfo: assetId empty')
        return nil
    end
    local path = '/assets/' .. assetId
    local parsedResponse = self:doGetRequest(path)
    return parsedResponse
end

function ImmichAPI:checkIfAlbumExists(albumId)
    if util.nilOrEmpty(albumId) then return false end
    log:trace("ImmichAPI: checkIfAlbumExists")
    local albumInfo = self:doGetRequestAllow404('/albums/' .. albumId)
    return albumInfo ~= nil
end

function ImmichAPI:getAlbumInfo(albumId)
    if util.nilOrEmpty(albumId) then
        log:warn('getAlbumInfo: albumId empty')
        return nil
    end
    log:trace("ImmichAPI: getAlbumInfo for: " .. tostring(albumId))
    local albumInfo = self:doGetRequest( '/albums/' .. albumId)
    return albumInfo
end

function ImmichAPI:getAlbumAssetIds(albumId)
    if util.nilOrEmpty(albumId) then
        log:warn('getAlbumAssetIds: albumId empty')
        return {}
    end
    log:trace("ImmichAPI: getAlbumAssetIds for: " .. tostring(albumId))
    local albumInfo = self:doGetRequest( '/albums/' .. albumId)
    local assetIds = {}

    if albumInfo and albumInfo.assets then
        for i = 1, #albumInfo.assets do
            if albumInfo.assets[i] and albumInfo.assets[i].id then
                table.insert(assetIds, albumInfo.assets[i].id)
            end
        end
    end

    return assetIds
end

-- ---------------------------------------------------------------------------
-- HTTP request layer
-- ---------------------------------------------------------------------------

function ImmichAPI:doPostRequest(apiPath, postBody)
    if not ensureConnectivity(self) then return nil end

    logRequestStart(self, 'POST', apiPath)
    if postBody ~= nil then
        log:trace('ImmichAPI: Postbody ' .. JSON:encode(postBody))
    end
    local response, headers = LrHttp.post(self.url .. self.apiBasePath .. apiPath, JSON:encode(postBody), self:createHeaders())

    if not headers then
        log:error('ImmichAPI POST: no response headers (network error): ' .. apiPath)
        util.handleError('Connection failed', 'No response from Immich server. Check URL and network.')
        return nil
    end
    if SUCCESS_STATUS_POST[headers.status] then
        log:trace('ImmichAPI POST request succeeded: ' .. tostring(response))
        return safeDecodeJson(response, 'POST')
    end
    handleRequestFailure('POST', apiPath, headers.status, headers, response)
    return nil
end

function ImmichAPI:doCustomRequest(method, apiPath, postBody)
    if not ensureConnectivity(self) then return nil end

    logRequestStart(self, method, apiPath)
    if postBody ~= nil then
        log:trace('ImmichAPI: Postbody ' .. JSON:encode(postBody))
    end
    local url = self.url .. self.apiBasePath .. apiPath
    local response, headers = LrHttp.post(url, JSON:encode(postBody or {}), self:createHeaders(), method, HTTP_TIMEOUT_DEFAULT)

    if not headers then
        log:error('ImmichAPI ' .. tostring(method) .. ': no response headers (network error): ' .. apiPath)
        util.handleError('Connection failed', 'No response from Immich server. Check URL and network.')
        return nil
    end
    if SUCCESS_STATUS_CUSTOM[headers.status] then
        log:trace('ImmichAPI ' .. method .. ' request succeeded: ' .. tostring(response))
        if util.nilOrEmpty(response) then return {} end
        return safeDecodeJson(response, method) or {}
    end
    handleRequestFailure(method, apiPath, headers.status, headers, response)
    return nil
end

function ImmichAPI:doGetRequest(apiPath)
    if not ensureConnectivity(self) then return nil end

    logRequestStart(self, 'GET', apiPath)
    local response, headers = LrHttp.get(self.url .. self.apiBasePath .. apiPath, self:createHeaders())

    if not headers then
        log:error('ImmichAPI GET: no response headers (network error): ' .. apiPath)
        util.handleError('Connection failed', 'No response from Immich server. Check URL and network.')
        return nil
    end
    if headers.status == SUCCESS_STATUS_GET then
        log:trace('ImmichAPI GET request succeeded')
        return safeDecodeJson(response, 'GET')
    end
    handleRequestFailure('GET', apiPath, headers.status, headers, response)
    return nil
end

-- GET that treats 400/404 as "not found" and returns nil without error (e.g. album deleted on server).
function ImmichAPI:doGetRequestAllow404(apiPath)
    if not ensureConnectivity(self) then return nil end

    logRequestStart(self, 'GET', apiPath)
    local response, headers = LrHttp.get(self.url .. self.apiBasePath .. apiPath, self:createHeaders())

    if not headers then
        log:error('ImmichAPI GET: no response headers (network error): ' .. apiPath)
        util.handleError('Connection failed', 'No response from Immich server. Check URL and network.')
        return nil
    end
    if headers.status == SUCCESS_STATUS_GET then
        log:trace('ImmichAPI GET request succeeded')
        return safeDecodeJson(response, 'GET')
    end
    if headers.status == 404 or headers.status == 400 then
        log:trace('ImmichAPI GET: resource not found (' .. tostring(headers.status) .. '): ' .. apiPath)
        return nil
    end
    handleRequestFailure('GET', apiPath, headers.status, headers, response)
    return nil
end

function ImmichAPI:doMultiPartPostRequest(apiPath, mimeChunks)
    if not ensureConnectivity(self) then return nil end

    logRequestStart(self, 'multipart POST', apiPath)
    local response, headers = LrHttp.postMultipart(self.url .. self.apiBasePath .. apiPath, mimeChunks, self:createHeadersForMultipart())

    if not headers then
        log:error('ImmichAPI multipart POST: no response headers (network error): ' .. apiPath)
        util.handleError('Connection failed', 'No response from Immich server. Check URL and network.')
        return nil
    end
    if SUCCESS_STATUS_POST[headers.status] then
        return safeDecodeJson(response, 'multipart POST')
    end
    handleRequestFailure('multipart POST', apiPath, headers.status, headers, response)
    return nil
end

function ImmichAPI:doMultiPartPutRequest(apiPath, filePath, formData)
    if not ensureConnectivity(self) then return nil end

    logRequestStart(self, 'multipart PUT', apiPath)
    local url = self.url .. self.apiBasePath .. apiPath
    local boundary = generateBoundary()
    local body = generateMultiPartBody(boundary, formData, filePath)
    if not body then
        log:error('doMultiPartPutRequest: failed to build multipart body for ' .. tostring(filePath))
        util.handleError('Upload failed', 'Could not read or build upload data. Check file path and permissions.')
        return nil
    end
    local reqhdrs = self:createHeadersForMultipartPut(boundary, string.len(body))
    log:trace('ImmichAPI multipart PUT headers:' .. util.dumpTable(reqhdrs))

    local response, headers = LrHttp.post(url, body, reqhdrs, 'PUT', HTTP_TIMEOUT_UPLOAD)
    if headers then
        log:trace('ImmichAPI multipart PUT response headers ' .. util.dumpTable(headers))
    end

    if not headers then
        log:error('ImmichAPI multipart PUT: no response headers (network error): ' .. apiPath)
        util.handleError('Connection failed', 'No response from Immich server. Check URL and network.')
        return nil
    end
    if SUCCESS_STATUS_POST[headers.status] then
        log:trace('ImmichAPI multipart PUT request succeeded: ' .. tostring(response))
        return safeDecodeJson(response, 'multipart PUT')
    end
    handleRequestFailure('multipart PUT', apiPath, headers.status, headers, response)
    return nil
end
