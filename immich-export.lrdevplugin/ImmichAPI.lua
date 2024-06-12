local LrHttp = import 'LrHttp'
local LrDate = import 'LrDate'
local LrPathUtils = import 'LrPathUtils'
local LrErrors = import 'LrErrors'
local LrDialogs = import 'LrDialogs'
local prefs = import 'LrPrefs'.prefsForPlugin() 
local log = import 'LrLogger'( 'ImmichPlugin' )
log:enable( 'logfile' )

local JSON = require "JSON"
local inspect = require 'inspect'

ImmichAPI = {}

-- Utility function to log errors and throw user errors
local function handleError(logMsg, userErrorMsg)
    log:error(logMsg)
    LrDialogs.showError(userErrorMsg)
end

-- Utility function to create headers
local function createHeaders(apiKey)
    return {
        { field = 'x-api-key', value = apiKey },
        { field = 'Accept', value = 'application/json' },
        { field = 'Content-Type', value = 'application/json' }
    }
end

-- Utility function to create headers for uploadAsset
local function createHeadersForMultipart(apiKey)
    return {
        { field = 'x-api-key', value = apiKey },
        { field = 'Accept', value = 'application/json' }
    }
end

-- Utility function to dump tables as JSON scrambling the API key.
local function dumpTable(t) 
    local s = inspect(t)
    local pattern = '(field = "x%-api%-key",%s+value = ")%w+(")'
    return s:gsub(pattern, '%1xxx%2')
end

function ImmichAPI.sanityCheckAndFixURL(url)
    if not url then
        handleError('sanityCheckAndFixURL: URL is empty', "Error: Immich server URL is empty.")
        return false
    end

    local sanitizedURL = string.match(url, "^https?://[%w%.]+[:%d]*")
    if sanitizedURL then
        if string.len(sanitizedURL) == string.len(url) then
            log:trace('sanityCheckAndFixURL: URL is completely sane.')
            return sanitizedURL
        else
            log:trace('sanityCheckAndFixURL: Fixed URL: removed trailing paths.')
            return sanitizedURL
        end
    elseif not string.match(url, "^https?://") then
        handleError('sanityCheckAndFixURL: URL is missing protocol (http:// or https://).')
    else
        handleError('sanityCheckAndFixURL: Unknown error in URL')
    end
    return nil
end

function ImmichAPI.checkConnectivity(url, apiKey)
	url = ImmichAPI.sanityCheckAndFixURL(url)
    if not url then 
        log:error('checkConnectivty: URL is empty')
        return false 
    end

    if not apiKey then
        handleError('checkConnectivity: API key is empty.', 'Immich API key is empty, cannot connect to Immich servers.')
        return false
    end


    log:trace('checkConnectivity: Sending validateToken request')
    local result, hdrs = LrHttp.post(url .. '/api/auth/validateToken', '', createHeaders(apiKey), 'POST', 1)
    

    if not result then
        log:error('checkConnectivity: Empty result from Immich server.')
        return false
    else
        log:trace('checkConnectivity: ' .. result)
        local decoded = JSON:decode(result)
        if decoded.authStatus == true then
            log:trace('checkConnectivity: connectivity is OK.')
            LrDialogs.message('Connection test successful.')
            return true
        else
            log:trace('checkConnectivity: authentication failed.' .. result)
            return false
        end
    end
end

function ImmichAPI.uploadAsset(url, apiKey, pathOrMessage)
    local uploadUrl = url .. '/api/asset/upload'
    local submitDate = LrDate.timeToIsoDate(LrDate.currentTime())
    local filePath = assert(pathOrMessage)
  	local fileName = LrPathUtils.leafName(filePath)

    local headerChunks = createHeadersForMultipart(apiKey)
    local mimeChunks = {
        { name = 'assetData', filePath = filePath, fileName = fileName, contentType = 'application/octet-stream' },
        { name = 'deviceAssetId', value = fileName },
        { name = 'deviceId', value = 'Lightroom Immich Upload Plugin' },
        { name = 'fileCreatedAt', value = submitDate },
        { name = 'fileModifiedAt', value = submitDate },
        { name = 'isFavorite', value = 'false' }
    }

	log:trace('uploadAsset: headerChunks' .. dumpTable(headerChunks))
	log:trace('uploadAsset: mimeChunls' .. dumpTable(mimeChunks))

    local result, hdrs = LrHttp.postMultipart(uploadUrl, mimeChunks, headerChunks)
    if not result then
        handleError('POST response headers: ' .. dumpTable(hdrs), "Error uploading some assets, please consult logs.")
        return nil
    else
        local parsedResult = JSON:decode(result)
		if parsedResult.id == nil then
			log:error('uploadAsset: Immich server did not retur an asset id')
			log:error('uploadAsset: Returned result: ' .. result)
			log:error('uploadAsset: Returned headers: ' .. dumpTable(hdr))
		end
        return parsedResult.id
    end
end

function ImmichAPI.addAssetToAlbum(url, apiKey, albumId, assetId)
    local addUrl = url .. '/api/album/' .. albumId .. '/assets'
    local headerChunks = createHeaders(apiKey)
    local postBody = { ids = { assetId } }

    local result, hdrs = LrHttp.post(addUrl, JSON:encode(postBody), headerChunks, 'PUT', 5)
    if not result then
        handleError('PUT response headers: ' .. dumpTable(hdrs), "Error adding asset to album, please consult logs.")
    else
        local decoded = JSON:decode(result)
        if not decoded[1].success then
            log:error("Unable to add asset (" .. assetId .. ") to album (" .. albumId .. ").")
            log:error(dumpTable(decoded))
        end
    end
end

function ImmichAPI.createAlbum(url, apiKey, albumName)
    local addUrl = url .. '/api/album'
    local headerChunks = createHeaders(apiKey)
    local postBody = { albumName = albumName }

    local result, hdrs = LrHttp.post(addUrl, JSON:encode(postBody), headerChunks)
    if not result then
        handleError('POST response headers: ' .. dumpTable(hdrs), "Error creating album, please consult logs.")
        return nil
    else
        local decoded = JSON:decode(result)
        if not decoded.id then
            handleError("Unable to create album (" .. albumName .. ").", "Error creating album, please consult logs.")
            return nil
        else
            return decoded.id
        end
    end
end

function ImmichAPI.deleteAlbum(url, apiKey, albumId)
    local addUrl = url .. '/api/album/' .. albumId
    local headerChunks = createHeaders(apiKey)

    local result, hdrs = LrHttp.post(addUrl, '{}', headerChunks, 'DELETE', 5)
    if not result then
        handleError('POST response headers: ' .. dumpTable(hdrs), "Error deleting album, please consult logs.")
        return false
    else
        local decoded = JSON:decode(result)
        if not decoded.success then
            handleError("Unable to delete album (" .. albumId .. ").", "Error deleting album, please consult logs.")
            return false
        else
            return true
        end
    end
end

function ImmichAPI.getAlbums(url, apiKey)

    local getUrl = url .. '/api/album'
    local headerChunks = createHeaders(apiKey)
    local result, hdrs = LrHttp.get(getUrl, headerChunks)

    local albums = {}
    if not result then
        handleError('GET response headers: ' .. dumpTable(hdrs), "Error getting album list from Immich, please consult logs.")
    else
        local decoded = JSON:decode(result)
        for i = 1, #decoded do
            local row = decoded[i]
            table.insert(albums, { title = row.albumName .. ' (' .. string.sub(row.createdAt, 1, 19) .. ')', value = row.id })
        end
    end
    return albums
end
