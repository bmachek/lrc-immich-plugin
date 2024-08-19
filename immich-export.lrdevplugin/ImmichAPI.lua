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
    -- o:checkConnectivity()
    -- log:trace('ImmichAPI object created: ' .. dumpTable(o))
    return o
end

function generateMultiPartBody(b, formData, filePath)

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

    local decoded = ImmichAPI:doPostRequest('/auth/validateToken', {})

    if decoded.authStatus == true then
        log:trace('checkConnectivity: connectivity is OK.')
        -- LrDialogs.message('Connection test successful.')
        return true
    else
        log:trace('checkConnectivity: authentication failed.' .. dumpTable(decoded))
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

    local formData = {
        -- { name = 'assetData', filePath = filePath, fileName = fileName, contentType = 'application/octet-stream' },
        { name = 'deviceAssetId', value = localId },
        { name = 'deviceId', value = self.deviceIdString },
        { name = 'fileCreatedAt', value = submitDate },
        { name = 'fileModifiedAt', value = submitDate },
    }

	log:trace('uploadAsset: mimeChunks' .. dumpTable(mimeChunks))
    parsedResult = ImmichAPI:doMultiPartPutRequest(apiPath, pathOrMessage, formData)
    if parsedResult.id == nil then
        log:error('replaceAsset: Immich server did not return an asset id')
        log:error('replaceAsset: Returned result: ' .. dumpTable(parsedResult))
        log:error('replaceAsset: Returned headers: ' .. dumpTable(hdr))
        return nil
    end
    return parsedResult.id
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
        handleError("Unable to create album (" .. albumName .. ").", "Error creating album, please consult logs.")
        return nil
    else
        return decoded.id
    end
end

function ImmichAPI:deleteAlbum(albumId)
    local path = '/albums/' .. albumId

    local decoded = ImmichAPI:doCustomRequest('DELETE', path)
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


function ImmichAPI:checkIfAssetExists(localId, filename, dateCreated)

    local id = tostring(localId)

    local postBody = { deviceAssetId = id, deviceId = self.deviceIdString, isTrashed = false }
    local response = ImmichAPI:doPostRequest('/search/metadata', postBody)

    if not response then
        log:trace('Asset with assetDeviceId ' .. id .. ' not found. No response')
		return nil
    elseif response.assets.count >= 1 then
        log:trace('Found existing asset with assetDeviceId ' .. tostring(localId))
        return response.assets.items[1].id, response.assets.items[1].deviceAssetId
	else
		log:trace('In Asset with assetDeviceId ' .. id .. ' not found')
		
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
    log:trace('ImmichAPI: Preparing POST request ' .. apiPath)
    local url = self.url .. self.apiBasePath .. apiPath

    local result, hdrs = LrHttp.post(url, JSON:encode(postBody), ImmichAPI:createHeaders(), method, 5)
    
    if not result then
        log:error('ImmichAPI POST request failed. ' .. apiPath)
        log:error(dumpTable(hdrs))
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
        log:trace('ImmichAPI GET request succeeded')
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

function ImmichAPI:doMultiPartPutRequest(apiPath, filePath, formData)
    log:trace('ImmichAPI: Preparing POST request ' .. apiPath)
    local url = self.url .. self.apiBasePath .. apiPath
    local boundary = 'FIXMEASTHISISSTATICFORNOWBUTSHOULDBERANDOM' -- TODO/FIXME
    
    local body = generateMultiPartBody(boundary, formData, filePath)
    local size = string.len(body)
    local reqhdrs = ImmichAPI:createHeadersForMultipartPut(boundary, size)
    
    log:trace('ImmichAPI multipart PUT headers:' .. dumpTable(reqhdrs))
    log:trace('ImmichAPI multipart PUT body:' .. body)


    local result, hdrs = LrHttp.post(url, body, reqhdrs, 'PUT', 15)
       
    if not result then
        log:error('ImmichAPI multipart PUT request failed. ' .. apiPath)
        log:error(dumpTable(hdrs))
        return false
    else
        log:trace('ImmichAPI multipart PUT request succeeded: ' .. result)
        local decoded = JSON:decode(result)
        return decoded
    end
end
