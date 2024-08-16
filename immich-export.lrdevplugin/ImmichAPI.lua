local LrHttp = import 'LrHttp'
local LrDate = import 'LrDate'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrTasks = import 'LrTasks'
local LrErrors = import 'LrErrors'
local LrDialogs = import 'LrDialogs'
local prefs = import 'LrPrefs'.prefsForPlugin() 
local log = import 'LrLogger'( 'ImmichPlugin' )
log:enable( 'logfile' )

local JSON = require "JSON"
local inspect = require 'inspect'

ImmichAPI = {}
ImmichAPI.__index = ImmichAPI


function ImmichAPI:new(url, apiKey)
    local o = setmetatable({}, ImmichAPI)
    self.url = url
    self.apiKey = apiKey
    self.deviceIdString = 'Lightroom Immich Upload Plugin'
    self.apiBasePath = '/api'
    o:sanityCheckAndFixURL()
    -- log:trace('ImmichAPI object created: ' .. dumpTable(o))
    return o
end

-- Utility function to log errors and throw user errors
function handleError(logMsg, userErrorMsg)
    log:error(logMsg)
    LrDialogs.showError(userErrorMsg)
end

-- Utility function to create headers
function ImmichAPI:createHeaders()
    return {
        { field = 'x-api-key', value = self.apiKey },
        { field = 'Accept', value = 'application/json' },
        { field = 'Content-Type', value = 'application/json' }
    }
end

-- Utility function to create headers for uploadAsset
function ImmichAPI:createHeadersForMultipart()
    return {
        { field = 'x-api-key', value = self.apiKey },
        { field = 'Accept', value = 'application/json' },
        -- { field = 'Content-Type', value = 'multipart/form-data' }
    }
end

-- Utility function to dump tables as JSON scrambling the API key.
function dumpTable(t) 
    local s = inspect(t)
    local pattern = '(field = "x%-api%-key",%s+value = ")%w+(")'
    return s:gsub(pattern, '%1xxx%2')
end

function ImmichAPI:sanityCheckAndFixURL()
    if not self.url then
        handleError('sanityCheckAndFixURL: URL is empty', "Error: Immich server URL is empty.")
        return false
    end

    local sanitizedURL = string.match(self.url, "^https?://[%w%.%-]+[:%d]*")
    if sanitizedURL then
        if string.len(sanitizedURL) == string.len(self.url) then
            log:trace('sanityCheckAndFixURL: URL is completely sane.')
            self.url = sanitizedURL
        else
            log:trace('sanityCheckAndFixURL: Fixed URL: removed trailing paths.')
            self.url = sanitizedURL
        end
    elseif not string.match(self.url, "^https?://") then
        handleError('sanityCheckAndFixURL: URL is missing protocol (http:// or https://).')
    else
        handleError('sanityCheckAndFixURL: Unknown error in URL')
    end
    -- self.url = nil
    return self.url
end

function ImmichAPI:checkConnectivity()
    log:trace('checkConnectivity: Sending validateToken request')

    local decoded = ImmichAPI:doPostRequest('/auth/validateToken') -- FIXME

    if decoded.authStatus == true then
        log:trace('checkConnectivity: connectivity is OK.')
        LrDialogs.message('Connection test successful.')
        return true
    else
        log:trace('checkConnectivity: authentication failed.' .. result)
        return false
    end
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

	log:trace('uploadAsset: mimeChunks' .. dumpTable(mimeChunks))
    parsedResult = ImmichAPI:doMultiPartPostRequest(apiPath, mimeChunks)
    if parsedResult.id == nil then
        log:error('uploadAsset: Immich server did not retur an asset id')
        log:error('uploadAsset: Returned result: ' .. dumpTable(parsedResult))
        log:error('uploadAsset: Returned headers: ' .. dumpTable(hdr))
    end
    return parsedResult.id
end

function ImmichAPI:replaceAsset(immichId, pathOrMessage, localId)
    local apiPath = '/assets/' .. immichId .. '/original'
    local submitDate = LrDate.timeToIsoDate(LrDate.currentTime())
    local filePath = pathOrMessage
  	local fileName = LrPathUtils.leafName(filePath)

    local mimeChunks = {
        { name = 'assetData', filePath = filePath, fileName = fileName, contentType = 'application/octet-stream' },
        { name = 'deviceAssetId', value = localId },
        { name = 'deviceId', value = self.deviceIdString },
        { name = 'fileCreatedAt', value = submitDate },
        { name = 'fileModifiedAt', value = submitDate },
    }

	log:trace('uploadAsset: mimeChunks' .. dumpTable(mimeChunks))
    parsedResult = ImmichAPI:doMultiPartPostRequest(apiPath, mimeChunks)
    if parsedResult.id == nil then
        log:error('replaceAsset: Immich server did not retur an asset id')
        log:error('replaceAsset: Returned result: ' .. dumpTable(parsedResult))
        log:error('replaceAsset: Returned headers: ' .. dumpTable(hdr))
        return nil
    end
    return parsedResult.id
end

function ImmichAPI:addAssetToAlbum(albumId, assetId)
    local apiPath = url .. '/albums/' .. albumId .. '/assets'
    local postBody = { ids = { assetId } }

    local decoded = ImmichAPI:doDAVRequest('PUT', apiPath, postBody)
    if not decoded[1].success then
        log:error("Unable to add asset (" .. assetId .. ") to album (" .. albumId .. ").")
        log:error(dumpTable(decoded))
    end
end

function ImmichAPI:createAlbum(albumName)
    local apiPath = '/albums'
    local postBody = { albumName = albumName }

    local decoded = ImmichAPI:doDAVRequest('PUT', apiPath, postBody)
    if not decoded.id then
        handleError("Unable to create album (" .. albumName .. ").", "Error creating album, please consult logs.")
        return nil
    else
        return decoded.id
    end
end

function ImmichAPI:deleteAlbum(albumId)
    local path = '/albums/' .. albumId

    local decoded = ImmichAPI:doDAVRequest('DELETE', path)
    if not decoded.success then
        handleError("Unable to delete album (" .. albumId .. ").", "Error deleting album, please consult logs.")
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


function ImmichAPI:checkIfAssetExists(localId)

    local id = tostring(localId)

    local postBody = { deviceAssetId = id, deviceId = self.deviceIdString, isTrashed = false }
    local response = ImmichAPI:doPostRequest('/search/metadata', postBody)

    if not response then
        log:trace('Asset with assetDeviceId ' .. id .. ' not found')
        return nil
    elseif response.assets.count >= 1 then
        log:trace('Found existing asset with assetDeviceId ' .. tostring(localId))
        return response.assets.items[1].id
    end
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

function ImmichAPI:doDAVRequest(method, apiPath, postBody)
    log:trace('ImmichAPI: Preparing POST request ' .. apiPath)
    local url = self.url .. self.apiBasePath .. apiPath

    local result, hdrs = LrHttp.post(url, postBody, ImmichAPI:createHeaders(), method, 5)
    
    if not result then
        log:error('ImmichAPI POST request failed. ' .. apiPath)
        return false
    else
        log:trace('ImmichAPI POST request succeeded: ' .. result)
        local decoded = JSON:decode(result)
        return decoded
    end
end

function ImmichAPI:doGetRequest(apiPath)
    log:trace('ImmichAPI: Preparing GET request ' .. apiPath)
    -- log:trace(dumpTable(self))
    local result, hdrs = LrHttp.get(self.url .. self.apiBasePath .. apiPath, ImmichAPI:createHeaders())
    
    if not result then
        log:error('ImmichAPI GET request failed. ' .. apiPath)
        return false
    else
        log:trace('ImmichAPI GET request succeeded: ' .. result)
        local decoded = JSON:decode(result)
        return decoded
    end
end


function ImmichAPI:doMultiPartPostRequest(apiPath, mimeChunks)
    local result, hdrs = LrHttp.postMultipart(self.url .. self.apiBasePath .. apiPath, mimeChunks, ImmichAPI:createHeadersForMultipart())
    if not result then
        handleError('POST response headers: ' .. dumpTable(hdrs), "Error uploading some assets, please consult logs.")
        return nil
    else
        local parsedResult = JSON:decode(result)
        return parsedResult
    end
end