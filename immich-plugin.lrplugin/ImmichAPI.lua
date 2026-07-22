--[[
    ImmichAPI – Lua client for Immich server API.
    Handles connectivity, assets, albums, stacks, and HTTP request/response.
]]

-- Constants
local API_BASE_PATH = "/api"
local HTTP_TIMEOUT_DEFAULT = 30
local HTTP_TIMEOUT_UPLOAD = 300

local SUCCESS_STATUS_GET = 200
local SUCCESS_STATUS_POST = { [200] = true, [201] = true }
local SUCCESS_STATUS_CUSTOM = { [200] = true, [201] = true, [204] = true }

ImmichAPI = {}
ImmichAPI.__index = ImmichAPI

-- ---------------------------------------------------------------------------
-- Private helpers
-- ---------------------------------------------------------------------------

local function safeDecodeJson(response, context)
    local ok, decoded = LrTasks.pcall(function()
        return JSON:decode(response or "{}")
    end)
    if not ok or decoded == nil then
        log:error("ImmichAPI " .. context .. ": JSON decode failed: " .. tostring(decoded))
        return nil
    end
    return decoded
end

local function ensureConnectivity(api)
    if not api:checkConnectivity() then
        ErrorHandler.handleError("Immich connection not setup. Go to module manager.", "Immich connection not setup.")
        return false
    end
    return true
end

local function logRequestStart(api, method, apiPath)
    log:trace("ImmichAPI: Preparing " .. method .. " request " .. api.url .. api.apiBasePath .. apiPath)
end

local function handleRequestFailure(method, apiPath, status, headers, response)
    -- Log the failure; do not show a modal dialog. During batch exports many requests can fail
    -- (e.g. one stack per photo). A modal dialog per failure would block the entire export and
    -- force the user to dismiss hundreds of popups. Callers check the nil return value and
    -- collect failures for the post-export summary shown by reportUploadFailuresAndWarnings.
    log:error(
        "ImmichAPI "
            .. tostring(method)
            .. " request failed: "
            .. apiPath
            .. " (status "
            .. tostring(status or "?")
            .. ")"
    )
    log:error("Response headers: " .. ((headers and Util.dumpTable(headers)) or "none"))
    local parsedErrorString = "HTTP " .. tostring(status or "Error")
    if response ~= nil then
        log:error("Response body: " .. tostring(response))
        local decoded = safeDecodeJson(response, "handleRequestFailure")
        if type(decoded) == "table" and decoded.message then
            if type(decoded.message) == "table" then
                parsedErrorString = parsedErrorString .. " - " .. table.concat(decoded.message, ", ")
            else
                parsedErrorString = parsedErrorString .. " - " .. tostring(decoded.message)
            end
        end
    end
    return parsedErrorString
end

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

function ImmichAPI:new(url, apiKey)
    local o = setmetatable({}, ImmichAPI)
    o.apiBasePath = API_BASE_PATH
    o.apiKey = (apiKey ~= nil and type(apiKey) == "string") and apiKey or ""
    o.url = (url ~= nil and type(url) == "string") and url or ""
    return o
end

function ImmichAPI:reconfigure(url, apiKey)
    self.apiKey = (apiKey ~= nil and type(apiKey) == "string") and apiKey or self.apiKey or ""
    self.url = (url ~= nil and type(url) == "string") and url or self.url or ""
    log:trace("Immich reconfigured with URL: " .. self.url)
    log:trace("Immich reconfigured with API key: " .. Util.cutApiKey(self.apiKey))
end

function ImmichAPI:setUrl(url)
    self.url = url
    log:trace("Immich new URL set: " .. self.url)
end

function ImmichAPI:setApiKey(apiKey)
    self.apiKey = apiKey
    log:trace("Immich new API key set: " .. Util.cutApiKey(self.apiKey))
end

-- ---------------------------------------------------------------------------
-- Assets
-- ---------------------------------------------------------------------------

function ImmichAPI:downloadAsset(assetId)
    if Util.nilOrEmpty(assetId) then
        ErrorHandler.handleError("No asset ID provided. Check logs.", "downloadAsset: assetId empty")
        return nil
    end

    local assetUrl = string.format("%s%s/assets/%s/original", self.url, self.apiBasePath, assetId)
    log:trace("Downloading asset from URL: " .. assetUrl)

    local response, headers = LrHttp.get(assetUrl, self:createHeaders())

    if not headers then
        log:error("downloadAsset: no response headers (network or server error) for asset " .. tostring(assetId))
        ErrorHandler.handleError(
            "Could not download asset. Check connection and Immich URL.",
            "downloadAsset: no response from server"
        )
        return nil
    end
    if headers.status == 200 then
        log:trace("Asset downloaded successfully: " .. assetId)
        return response
    else
        log:error("Failed to download asset: " .. assetId)
        log:error("Response headers: " .. Util.dumpTable(headers))
        if response ~= nil then
            log:error("Response body: " .. response)
        end
        return nil
    end
end

function ImmichAPI:hasLivePhotoVideo(assetId)
    if Util.nilOrEmpty(assetId) then
        ErrorHandler.handleError("No asset ID provided. Check logs.", "hasLivePhotoVideo: assetId empty")
        return nil
    end

    local path = "/assets/" .. assetId
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
    if Util.nilOrEmpty(assetId) then
        ErrorHandler.handleError("No asset ID provided. Check logs.", "getLivePhotoVideoId: assetId empty")
        return nil
    end

    local path = "/assets/" .. assetId
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
    if Util.nilOrEmpty(assetId) then
        ErrorHandler.handleError("No asset ID provided. Check logs.", "getOriginalFileName: assetId empty")
        return nil
    end

    local path = "/assets/" .. assetId
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
    if Util.nilOrEmpty(albumId) then
        ErrorHandler.handleError("No album ID provided. Check logs.", "getAlbumAssets: albumId empty")
        return nil
    end

    local assets = {}
    local page = 1
    repeat
        local postBody = { albumIds = { albumId }, page = page, size = 250 }
        local response = self:doPostRequest("/search/metadata", postBody)

        if not response or type(response) ~= "table" or not response.assets then
            log:error("getAlbumAssets: search/metadata failed for album ID: " .. albumId .. " (page " .. page .. ")")
            return nil
        end

        for _, asset in ipairs(response.assets.items or {}) do
            table.insert(assets, {
                id = asset.id,
                originalFileName = asset.originalFileName,
            })
        end

        -- nextPage is a string page number (or nil/JSON null when there are no more pages).
        page = tonumber(response.assets.nextPage)
    until not page

    log:trace("getAlbumAssets: Retrieved " .. #assets .. " assets for album ID: " .. albumId)
    return assets
end

-- Run Immich's smart (CLIP) search for a free-text query and return the matching assets.
-- Returns the same { id, originalFileName } shape as getAlbumAssets so callers can reuse the
-- same downloader. Returns nil on request failure (distinct from an empty table = no matches).
function ImmichAPI:searchSmart(query)
    if Util.nilOrEmpty(query) then
        ErrorHandler.handleError("No search query provided. Check logs.", "searchSmart: query empty")
        return nil
    end

    local assets = {}
    local page = 1
    repeat
        local postBody = { query = query, page = page, size = 250 }
        local response = self:doPostRequest("/search/smart", postBody)

        if not response or type(response) ~= "table" or not response.assets then
            log:error("searchSmart: search/smart failed for query: " .. query .. " (page " .. page .. ")")
            return nil
        end

        for _, asset in ipairs(response.assets.items or {}) do
            table.insert(assets, {
                id = asset.id,
                originalFileName = asset.originalFileName,
            })
        end

        -- nextPage is a string page number (or nil/JSON null when there are no more pages).
        page = tonumber(response.assets.nextPage)
    until not page

    log:trace("searchSmart: Retrieved " .. #assets .. " assets for query: " .. query)
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
        { field = "x-api-key", value = safeApiKey(self) },
        { field = "Accept", value = "application/json" },
        { field = "Content-Type", value = "application/json" },
    }
end

function ImmichAPI:createHeadersForMultipart()
    return {
        { field = "x-api-key", value = safeApiKey(self) },
        { field = "Accept", value = "application/json" },
    }
end

-- Returns sanitized URL (string) on success; false on empty; nil on invalid format.
-- Does not show dialogs (for use in validate callbacks). Callers should show errors or return error messages.
function ImmichAPI:sanityCheckAndFixURL(url)
    if Util.nilOrEmpty(url) then
        return false
    end
    if not string.match(url, "^https?://") then
        return nil
    end
    local sanitized = string.match(url, "^https?://[%w%.%-]+[:%d]*")
    if not sanitized then
        return nil
    end
    if string.len(sanitized) < string.len(url) then
        log:trace("sanityCheckAndFixURL: removed trailing path from URL.")
    end
    return sanitized
end

function ImmichAPI:checkConnectivity()
    if Util.nilOrEmpty(self.url) or Util.nilOrEmpty(self.apiKey) then
        log:error("checkConnectivity: URL or API key is empty. Configure in plugin settings.")
        return false
    end

    local response, headers = LrHttp.get(self.url .. self.apiBasePath .. "/users/me", self:createHeaders())

    if not headers then
        log:error("checkConnectivity: no response headers (network error or invalid URL)")
        return false
    end
    if headers.status == 200 then
        -- log:trace('checkConnectivity: test OK.')
        return true
    else
        log:error("checkConnectivity: test failed.")
        log:error("Response headers: " .. Util.dumpTable(headers))
        local errReason = "HTTP " .. tostring(headers.status)
        if response ~= nil then
            log:error("Response body: " .. response)
            local decoded = safeDecodeJson(response, "checkConnectivity")
            if type(decoded) == "table" and decoded.message then
                errReason = errReason .. " - " .. tostring(decoded.message)
            end
        end
        return false, errReason
    end
end

-- ---------------------------------------------------------------------------
-- Dialog helpers (URL validation and test connection for Publish/Export dialogs)
-- ---------------------------------------------------------------------------

local function _trimString(s)
    if type(s) ~= "string" then
        return ""
    end
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
    local ok, errReason = api:checkConnectivity()
    if ok then
        return true, "Connection test successful", api
    end
    return false, "Connection test failed: " .. tostring(errReason or "Check URL, API key, and network."), api
end

-- Thanks to Min Idzelis
function ImmichAPI:getAlbumUrl(albumId)
    if Util.nilOrEmpty(albumId) then
        return nil
    end
    return self.url .. "/albums/" .. albumId
end

-- Thanks to Min Idzelis
function ImmichAPI:getAssetUrl(id)
    if Util.nilOrEmpty(id) then
        return nil
    end
    return self.url .. "/photos/" .. id
end

function ImmichAPI:uploadAsset(pathOrMessage, visibility)
    if Util.nilOrEmpty(pathOrMessage) then
        ErrorHandler.handleError("No filename given. Check logs.", "uploadAsset: pathOrMessage empty")
        return nil
    end

    local apiPath = "/assets"
    -- Immich requires a strict ISO 8601 datetime with an explicit timezone (a 'Z' or
    -- a colon-separated offset, e.g. 2026-07-03T05:13:22.583Z). On this SDK
    -- LrDate.timeToW3CDate returns a naive UTC timestamp with no zone designator, so
    -- append 'Z'. If a build ever returns an offset already, normalize +0200 -> +02:00.
    local submitDate = LrDate.timeToW3CDate(LrDate.currentTime())
    if submitDate:match("[Zz]$") or submitDate:match("[%+%-]%d%d:?%d%d$") then
        submitDate = submitDate:gsub("([+-]%d%d)(%d%d)$", "%1:%2")
    else
        submitDate = submitDate .. "Z"
    end
    log:trace("uploadAsset: " .. tostring(pathOrMessage) .. " submitted at " .. submitDate)
    local filePath = pathOrMessage
    local fileName = LrPathUtils.leafName(filePath)

    local mimeChunks = {
        {
            name = "assetData",
            filePath = filePath,
            fileName = fileName,
            contentType = "application/octet-stream",
        },
        { name = "fileCreatedAt", value = submitDate },
        { name = "fileModifiedAt", value = submitDate },
        { name = "isFavorite", value = "false" },
    }
    if visibility and visibility ~= "" then
        table.insert(mimeChunks, { name = "visibility", value = visibility })
    end

    local parsedResponse, errReason = self:doMultiPartPostRequest(apiPath, mimeChunks)
    if parsedResponse ~= nil then
        log:info("uploadAsset: " .. tostring(pathOrMessage) .. " -> " .. parsedResponse.id)
        return parsedResponse.id
    end
    return nil, errReason
end

-- Replaces an asset the plugin previously uploaded. immichId must come from a
-- trusted source (the Immich asset ID the plugin persisted in Lightroom photo
-- metadata via checkIfAssetExistsEnhanced) — since Immich removed deviceId there
-- is no longer any way to verify ownership of an asset resolved by filename/date,
-- so callers must never pass an id obtained from a heuristic match.
function ImmichAPI:replaceAsset(immichId, pathOrMessage, visibility)
    if Util.nilOrEmpty(immichId) then
        ErrorHandler.handleError("Immich asset ID missing. Check logs.", "replaceAsset: immichId empty")
        return nil
    end

    if Util.nilOrEmpty(pathOrMessage) then
        ErrorHandler.handleError("No filename given. Check logs.", "replaceAsset: pathOrMessage empty")
        return nil
    end

    -- Upload to regular library first so copy/delete work even when the target
    -- visibility is "locked" (Immich blocks copy and delete on locked assets).
    -- Visibility is applied after metadata is transferred.
    local newImmichId, errReason = self:uploadAsset(pathOrMessage, nil)
    if newImmichId ~= nil then
        -- Immich may return the existing asset ID (e.g. duplicate detection); skip replace steps
        if newImmichId == immichId then
            log:trace("replaceAsset: Upload returned same ID, no replace needed: " .. immichId)
            if visibility then
                self:setAssetVisibility(newImmichId, visibility)
            end
            return immichId
        end
        -- If the old asset no longer exists, nothing to copy/delete.
        local oldAssetInfo = self:doGetRequestAllow404("/assets/" .. immichId)
        if oldAssetInfo == nil then
            log:info("replaceAsset: old asset " .. immichId .. " no longer exists on server, returning new asset")
            if visibility then
                self:setAssetVisibility(newImmichId, visibility)
            end
            return newImmichId
        end
        if self:copyAssetMetadata(immichId, newImmichId) then
            if visibility then
                self:setAssetVisibility(newImmichId, visibility)
            end
            if self:deleteAsset(immichId) then
                log:info("replaceAsset: " .. immichId .. " -> " .. newImmichId)
                return newImmichId
            else
                -- Old asset may be in locked folder; log and continue with new ID.
                log:warn("replaceAsset: failed to delete old asset " .. immichId .. " (may be in locked folder)")
                return newImmichId
            end
        else
            ErrorHandler.handleError(
                "Failed to copy metadata to new asset after replacement. Check logs. New asset will be deleted.",
                "replaceAsset: Failed to copy metadata from old asset " .. immichId .. " to new asset " .. newImmichId
            )
            self:deleteAsset(newImmichId)
            return nil, "Metadata copy failed"
        end
    end
    return nil, errReason
end

function ImmichAPI:setAssetVisibility(assetId, visibility)
    if Util.nilOrEmpty(assetId) then
        log:warn("setAssetVisibility: assetId empty")
        return false
    end
    local body = { ids = { assetId }, visibility = visibility }
    local parsedResponse = self:doCustomRequest("PUT", "/assets", body)
    if parsedResponse == nil then
        log:error("setAssetVisibility: failed to set visibility " .. tostring(visibility) .. " on " .. assetId)
        return false
    end
    log:trace("setAssetVisibility: " .. assetId .. " -> " .. tostring(visibility))
    return true
end

-- Set the capture date (dateTimeOriginal) on an existing asset, mirroring the
-- web UI's date editor. Used to push Lightroom's edited capture time for assets
-- Immich cannot read it from the file (videos). Immich persists this to a
-- sidecar, so it survives later metadata re-extraction.
function ImmichAPI:setAssetDate(assetId, isoDate)
    if Util.nilOrEmpty(assetId) or Util.nilOrEmpty(isoDate) then
        log:warn("setAssetDate: assetId or date empty")
        return false
    end
    local body = { dateTimeOriginal = isoDate }
    local parsedResponse = self:doCustomRequest("PUT", "/assets/" .. assetId, body)
    if parsedResponse == nil then
        log:error("setAssetDate: failed to set date " .. tostring(isoDate) .. " on " .. assetId)
        return false
    end
    log:trace("setAssetDate: " .. assetId .. " -> " .. tostring(isoDate))
    return true
end

-- Upsert tags by value (supports nested "parent/child"). Returns the array of
-- tag objects ({ id, name, value }) on success, or nil.
function ImmichAPI:upsertTags(tagNames)
    if type(tagNames) ~= "table" or #tagNames == 0 then
        return nil
    end
    local body = { tags = tagNames }
    local parsedResponse = self:doCustomRequest("PUT", "/tags", body)
    if parsedResponse == nil then
        log:error("upsertTags: failed to upsert tags")
        return nil
    end
    return parsedResponse
end

-- Assign already-upserted tag ids to a single asset (bulk endpoint).
function ImmichAPI:assignTagsToAsset(tagIds, assetId)
    if type(tagIds) ~= "table" or #tagIds == 0 or Util.nilOrEmpty(assetId) then
        return false
    end
    local body = { tagIds = tagIds, assetIds = { assetId } }
    local parsedResponse = self:doCustomRequest("PUT", "/tags/assets", body)
    if parsedResponse == nil then
        log:error("assignTagsToAsset: failed to assign tags to " .. assetId)
        return false
    end
    log:trace("assignTagsToAsset: " .. #tagIds .. " tag(s) -> " .. assetId)
    return true
end

-- Poll until Immich has finished ingesting the asset (thumbnail generated).
-- A freshly uploaded video is probed and thumbnailed asynchronously; mutating its
-- metadata before that completes races the ingest pipeline and leaves the
-- thumbnail in an error state. Returns true once ready, false on timeout.
function ImmichAPI:waitForAssetReady(assetId, maxSeconds)
    if Util.nilOrEmpty(assetId) then
        return false
    end
    local limit = maxSeconds or 30
    local waited = 0
    while waited < limit do
        local asset = self:doGetRequest("/assets/" .. assetId)
        if asset ~= nil and type(asset.thumbhash) == "string" and asset.thumbhash ~= "" then
            return true
        end
        LrTasks.sleep(1)
        waited = waited + 1
    end
    log:warn("waitForAssetReady: timed out after " .. limit .. "s waiting for " .. assetId)
    return false
end

-- Queue a thumbnail regeneration for an asset (same action as the web UI's
-- "Regenerate thumbnails"). Used after a metadata change so a video whose
-- thumbnail was invalidated recovers on its own. Returns true on success.
function ImmichAPI:regenerateThumbnail(assetId)
    if Util.nilOrEmpty(assetId) then
        return false
    end
    local body = { assetIds = { assetId }, name = "regenerate-thumbnail" }
    local parsedResponse = self:doCustomRequest("POST", "/assets/jobs", body)
    if parsedResponse == nil then
        log:error("regenerateThumbnail: failed to queue for " .. assetId)
        return false
    end
    log:trace("regenerateThumbnail: queued for " .. assetId)
    return true
end

function ImmichAPI:copyAssetMetadata(sourceAssetId, targetAssetId)
    if Util.nilOrEmpty(sourceAssetId) then
        ErrorHandler.handleError(
            "Source Immich asset ID missing. Check logs.",
            "copyAssetMetadata: sourceAssetId empty"
        )
        return nil
    end

    if Util.nilOrEmpty(targetAssetId) then
        ErrorHandler.handleError(
            "Target Immich asset ID missing. Check logs.",
            "copyAssetMetadata: targetAssetId empty"
        )
        return nil
    end

    local apiPath = "/assets/copy"
    local body = { sourceId = sourceAssetId, targetId = targetAssetId }

    local parsedResponse = self:doCustomRequest("PUT", apiPath, body)
    if parsedResponse ~= nil then
        return true
    end
    return false
end

function ImmichAPI:deleteAsset(immichId)
    if Util.nilOrEmpty(immichId) then
        ErrorHandler.handleError("Immich asset ID missing. Check logs.", "deleteAsset: immichId empty")
        return false
    end

    local apiPath = "/assets"

    local body = { ids = { immichId } }

    local parsedResponse = self:doCustomRequest("DELETE", apiPath, body)
    if parsedResponse ~= nil then
        return true
    end
    return false
end

function ImmichAPI:removeAssetFromAlbum(albumId, assetId)
    if Util.nilOrEmpty(albumId) then
        ErrorHandler.handleError("Immich album ID missing. Check logs.", "removeAssetFromAlbum: albumId empty")
        return false
    end

    if Util.nilOrEmpty(assetId) then
        ErrorHandler.handleError("No Immich asset ID given. Check logs.", "removeAssetFromAlbum: assetId empty")
        return false
    end

    local apiPath = "/albums/" .. albumId .. "/assets"
    local postBody = { ids = { assetId } }

    local parsedResponse = self:doCustomRequest("DELETE", apiPath, postBody)
    if parsedResponse == nil then
        -- log:error("Unable to remove asset (" .. assetId .. ") from album (" .. albumId .. ").")
        return false
    end

    return true
end

function ImmichAPI:addAssetToAlbum(albumId, assetId)
    if Util.nilOrEmpty(albumId) then
        ErrorHandler.handleError("Immich album ID missing. Check logs.", "addAssetToAlbum: albumId empty")
        return nil
    end

    if Util.nilOrEmpty(assetId) then
        ErrorHandler.handleError("No Immich asset ID given. Check logs.", "addAssetToAlbum: assetId empty")
        return nil
    end

    local apiPath = "/albums/" .. albumId .. "/assets"
    local postBody = { ids = { assetId } }

    local parsedResponse = self:doCustomRequest("PUT", apiPath, postBody)
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
        ErrorHandler.handleError(
            "Need at least 2 assets to create a stack. Check logs.",
            "createStack: need at least 2 assets"
        )
        return nil
    end

    local apiPath = "/stacks"
    local postBody = { assetIds = assetIds }

    log:trace("Creating stack with assets: " .. JSON:encode(assetIds))

    local parsedResponse = self:doPostRequest(apiPath, postBody)
    if parsedResponse ~= nil then
        log:info("Stack created: " .. parsedResponse.id .. " (" .. #assetIds .. " assets)")
        return parsedResponse.id
    else
        log:error("Failed to create stack")
        return nil
    end
end

-- ---------------------------------------------------------------------------
-- Albums
-- ---------------------------------------------------------------------------

function ImmichAPI:createAlbum(albumName)
    if Util.nilOrEmpty(albumName) then
        ErrorHandler.handleError("No album name given. Check logs.", "createAlbum: albumName empty")
        return nil
    end

    local apiPath = "/albums"
    local postBody = { albumName = albumName }

    local parsedResponse = self:doPostRequest(apiPath, postBody)
    if parsedResponse ~= nil then
        return parsedResponse.id
    end
    return nil
end

function ImmichAPI:getAlbumNameById(albumId)
    if Util.nilOrEmpty(albumId) then
        ErrorHandler.handleError("No album ID given. Check logs.", "getAlbumNameById: albumId empty")
        return nil
    end

    local path = "/albums/" .. albumId
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
    if Util.nilOrEmpty(albumName) then
        ErrorHandler.handleError("No album name given. Check logs.", "createAlbum: albumName empty")
        return nil
    end

    local existingAlbums = self:getAlbumsByNameFolderBased(albumName)
    if existingAlbums ~= nil then
        if #existingAlbums > 0 then
            log:trace("Found existing folder based album with id: " .. existingAlbums[1].value)
            return existingAlbums[1].value
        end
    end

    local apiPath = "/albums"
    local postBody = { albumName = albumName, description = "Based on Lightroom folder: " .. albumName }

    local parsedResponse = self:doPostRequest(apiPath, postBody)
    if parsedResponse ~= nil then
        return parsedResponse.id
    end
    return nil
end

function ImmichAPI:deleteAlbum(albumId)
    if Util.nilOrEmpty(albumId) then
        ErrorHandler.handleError("No album ID provided. Cannot delete album.", "deleteAlbum: albumId empty")
        return false
    end
    local path = "/albums/" .. albumId

    local parsedResponse = self:doCustomRequest("DELETE", path, {})
    if parsedResponse == nil then
        ErrorHandler.handleError(
            "Error deleting album, please consult logs.",
            "Unable to delete album (" .. albumId .. ")."
        )
        return false
    else
        return true
    end
end

function ImmichAPI:renameAlbum(albumId, newName)
    if Util.nilOrEmpty(albumId) then
        ErrorHandler.handleError("No album ID provided. Cannot rename album.", "renameAlbum: albumId empty")
        return false
    end
    if Util.nilOrEmpty(newName) then
        ErrorHandler.handleError("No new name provided. Cannot rename album.", "renameAlbum: newName empty")
        return false
    end
    local path = "/albums/" .. albumId

    local postBody = {}
    postBody.albumName = newName

    local parsedResponse = self:doCustomRequest("PATCH", path, postBody)
    if parsedResponse == nil then
        ErrorHandler.handleError(
            "Error renaming album, please consult logs.",
            "Unable to rename album (" .. tostring(albumId) .. ")."
        )
        return false
    else
        return true
    end
end

function ImmichAPI:getAlbums()
    local path = "/albums"
    local parsedResponse = self:doGetRequest(path)
    local albums = {}
    if parsedResponse and type(parsedResponse) == "table" then
        for i = 1, #parsedResponse do
            local row = parsedResponse[i]
            if row and row.id and row.albumName then
                local createdAt = (row.createdAt and type(row.createdAt) == "string")
                        and string.sub(row.createdAt, 1, 19)
                    or ""
                table.insert(albums, { title = row.albumName .. " (" .. createdAt .. ")", value = row.id })
            end
        end
        return albums
    else
        return nil
    end
end

function ImmichAPI:getAlbumsWODate()
    local path = "/albums"
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
    if Util.nilOrEmpty(albumName) then
        return nil
    end
    local path = "/albums"
    local parsedResponse = self:doGetRequest(path)
    local albums = {}
    if parsedResponse and type(parsedResponse) == "table" then
        for i = 1, #parsedResponse do
            local row = parsedResponse[i]
            if
                row
                and row.id
                and row.albumName
                and row.albumName == albumName
                and (row.description or "") == ("Based on Lightroom folder: " .. albumName)
            then
                local createdAt = (row.createdAt and type(row.createdAt) == "string")
                        and string.sub(row.createdAt, 1, 19)
                    or ""
                table.insert(albums, { title = row.albumName .. " (" .. createdAt .. ")", value = row.id })
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
    if Util.nilOrEmpty(albumId) then
        log:warn("getActivities: albumId empty")
        return nil
    end
    local path = "/activities?albumId=" .. tostring(albumId)

    if assetId and assetId ~= "" then
        path = path .. "&assetId=" .. tostring(assetId)
    end

    local parsedResponse = self:doGetRequest(path)
    return parsedResponse
end

-- Resolve the Immich asset ID the plugin previously uploaded for this photo.
-- Immich removed deviceAssetId/deviceId, so the only trustworthy handle is the
-- asset ID the plugin persisted in Lightroom photo metadata (MetadataTask). We no
-- longer fall back to a deviceAssetId or filename+date search: without deviceId we
-- cannot prove ownership of a heuristically matched asset, and treating a foreign
-- asset (e.g. an external-library RAW sharing this photo's name/date) as a replace
-- target would trash it. When no stored ID exists, callers upload a fresh asset.
-- Returns the assetId if found and still present, nil otherwise.
function ImmichAPI:checkIfAssetExistsEnhanced(photo)
    require("MetadataTask")

    local storedAssetId = MetadataTask.getImmichAssetId(photo)
    if storedAssetId and storedAssetId ~= "" then
        -- Verify the asset still exists (and is not trashed) in Immich.
        local assetInfo = self:getAssetInfo(storedAssetId)
        if assetInfo and not assetInfo.isTrashed then
            log:trace("checkIfAssetExistsEnhanced: Found assetId in metadata: " .. storedAssetId)
            return storedAssetId
        end
        -- Asset was deleted in Immich; clear the stale metadata so we upload fresh.
        log:trace(
            "checkIfAssetExistsEnhanced: Stored assetId " .. storedAssetId .. " no longer exists, clearing metadata"
        )
        MetadataTask.setImmichAssetId(photo, nil)
    end

    return nil
end

function ImmichAPI:checkIfAssetIsInAnAlbum(immichId)
    if Util.nilOrEmpty(immichId) then
        log:warn("checkIfAssetIsInAnAlbum: immichId empty")
        return false
    end
    local postBody = { id = immichId, isNotInAlbum = true }
    local response = self:doPostRequest("/search/metadata", postBody)

    if response and type(response) == "table" and response.assets then
        local count = response.assets.count or 0
        local items = response.assets.items or {}
        if count == 1 and items[1] and not items[1].isTrashed then
            log:trace("checkIfAssetIsInAnAlbum: " .. tostring(immichId) .. " is NOT included in any album")
            return false
        end
    end

    log:trace("checkIfAssetIsInAnAlbum: " .. tostring(immichId) .. " is included in at least one album")
    return true
end

function ImmichAPI:getAssetInfo(assetId)
    if Util.nilOrEmpty(assetId) then
        log:warn("getAssetInfo: assetId empty")
        return nil
    end
    local path = "/assets/" .. assetId
    local parsedResponse = self:doGetRequest(path)
    return parsedResponse
end

function ImmichAPI:checkIfAlbumExists(albumId)
    if Util.nilOrEmpty(albumId) then
        return false
    end
    log:trace("ImmichAPI: checkIfAlbumExists")
    local albumInfo = self:doGetRequestAllow404("/albums/" .. albumId)
    return albumInfo ~= nil
end

function ImmichAPI:getAlbumInfo(albumId)
    if Util.nilOrEmpty(albumId) then
        log:warn("getAlbumInfo: albumId empty")
        return nil
    end
    log:trace("ImmichAPI: getAlbumInfo for: " .. tostring(albumId))
    local albumInfo = self:doGetRequest("/albums/" .. albumId)
    return albumInfo
end

function ImmichAPI:getAlbumAssetIds(albumId)
    if Util.nilOrEmpty(albumId) then
        log:warn("getAlbumAssetIds: albumId empty")
        return {}
    end
    log:trace("ImmichAPI: getAlbumAssetIds for: " .. tostring(albumId))
    local albumInfo = self:doGetRequest("/albums/" .. albumId)
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
-- Shared links
-- ---------------------------------------------------------------------------

-- Create an "individual" shared link covering the given asset IDs.
-- opts: { expiresAt = ISO-8601 string or nil, password = string or nil, allowDownload = bool }
-- Returns the full share URL (<serverUrl>/share/<key>) on success; nil + error reason otherwise.
function ImmichAPI:createSharedLink(assetIds, opts)
    if type(assetIds) ~= "table" or #assetIds == 0 then
        ErrorHandler.handleError("No assets to share. Check logs.", "createSharedLink: empty assetIds")
        return nil
    end
    opts = opts or {}

    local postBody = {
        type = "INDIVIDUAL",
        assetIds = assetIds,
        allowDownload = opts.allowDownload ~= false,
        allowUpload = false,
    }
    if not Util.nilOrEmpty(opts.expiresAt) then
        postBody.expiresAt = opts.expiresAt
    end
    if not Util.nilOrEmpty(opts.password) then
        postBody.password = opts.password
    end

    local response, errReason = self:doPostRequest("/shared-links", postBody)
    if not response or Util.nilOrEmpty(response.key) then
        log:error("createSharedLink: no key returned in response")
        return nil, errReason
    end

    log:trace("createSharedLink: created link for " .. #assetIds .. " asset(s)")
    return self.url .. "/share/" .. response.key
end

-- ---------------------------------------------------------------------------
-- HTTP request layer
-- ---------------------------------------------------------------------------

function ImmichAPI:doPostRequest(apiPath, postBody)
    if not ensureConnectivity(self) then
        return nil
    end

    logRequestStart(self, "POST", apiPath)
    if postBody ~= nil then
        log:trace("ImmichAPI: Postbody " .. JSON:encode(postBody))
    end
    local response, headers = LrHttp.post(
        self.url .. self.apiBasePath .. apiPath,
        JSON:encode(postBody),
        self:createHeaders(),
        "POST",
        HTTP_TIMEOUT_DEFAULT
    )

    if not headers then
        log:error("ImmichAPI POST: no response headers (network error): " .. apiPath)
        ErrorHandler.handleError("No response from Immich server. Check URL and network.", "Connection failed")
        return nil
    end
    if SUCCESS_STATUS_POST[headers.status] then
        log:trace("ImmichAPI POST request succeeded: " .. tostring(response))
        return safeDecodeJson(response, "POST")
    end
    local errReason = handleRequestFailure("POST", apiPath, headers.status, headers, response)
    return nil, errReason
end

function ImmichAPI:doCustomRequest(method, apiPath, postBody)
    if not ensureConnectivity(self) then
        return nil
    end

    logRequestStart(self, method, apiPath)
    if postBody ~= nil then
        log:trace("ImmichAPI: Postbody " .. JSON:encode(postBody))
    end
    local url = self.url .. self.apiBasePath .. apiPath
    local response, headers =
        LrHttp.post(url, JSON:encode(postBody or {}), self:createHeaders(), method, HTTP_TIMEOUT_DEFAULT)

    if not headers then
        log:error("ImmichAPI " .. tostring(method) .. ": no response headers (network error): " .. apiPath)
        ErrorHandler.handleError("No response from Immich server. Check URL and network.", "Connection failed")
        return nil
    end
    if SUCCESS_STATUS_CUSTOM[headers.status] then
        log:trace("ImmichAPI " .. method .. " request succeeded: " .. tostring(response))
        if Util.nilOrEmpty(response) then
            return {}
        end
        return safeDecodeJson(response, method) or {}
    end
    local errReason = handleRequestFailure(method, apiPath, headers.status, headers, response)
    return nil, errReason
end

function ImmichAPI:doGetRequest(apiPath)
    if not ensureConnectivity(self) then
        return nil
    end

    logRequestStart(self, "GET", apiPath)
    local response, headers = LrHttp.get(self.url .. self.apiBasePath .. apiPath, self:createHeaders())

    if not headers then
        log:error("ImmichAPI GET: no response headers (network error): " .. apiPath)
        ErrorHandler.handleError("No response from Immich server. Check URL and network.", "Connection failed")
        return nil
    end
    if headers.status == SUCCESS_STATUS_GET then
        log:trace("ImmichAPI GET request succeeded")
        return safeDecodeJson(response, "GET")
    end
    local errReason = handleRequestFailure("GET", apiPath, headers.status, headers, response)
    return nil, errReason
end

-- GET that treats 400/404 as "not found" and returns nil without error (e.g. album deleted on server).
function ImmichAPI:doGetRequestAllow404(apiPath)
    if not ensureConnectivity(self) then
        return nil
    end

    logRequestStart(self, "GET", apiPath)
    local response, headers = LrHttp.get(self.url .. self.apiBasePath .. apiPath, self:createHeaders())

    if not headers then
        log:error("ImmichAPI GET: no response headers (network error): " .. apiPath)
        ErrorHandler.handleError("No response from Immich server. Check URL and network.", "Connection failed")
        return nil
    end
    if headers.status == SUCCESS_STATUS_GET then
        log:trace("ImmichAPI GET request succeeded")
        return safeDecodeJson(response, "GET")
    end
    if headers.status == 404 or headers.status == 400 then
        log:trace("ImmichAPI GET: resource not found (" .. tostring(headers.status) .. "): " .. apiPath)
        return nil
    end
    local errReason = handleRequestFailure("GET", apiPath, headers.status, headers, response)
    return nil, errReason
end

function ImmichAPI:doMultiPartPostRequest(apiPath, mimeChunks)
    if not ensureConnectivity(self) then
        return nil
    end

    logRequestStart(self, "multipart POST", apiPath)
    local response, headers = LrHttp.postMultipart(
        self.url .. self.apiBasePath .. apiPath,
        mimeChunks,
        self:createHeadersForMultipart(),
        HTTP_TIMEOUT_UPLOAD
    )

    if not headers then
        log:error("ImmichAPI multipart POST: no response headers (network error): " .. apiPath)
        ErrorHandler.handleError("No response from Immich server. Check URL and network.", "Connection failed")
        return nil
    end
    if SUCCESS_STATUS_POST[headers.status] then
        return safeDecodeJson(response, "multipart POST")
    end
    local errReason = handleRequestFailure("multipart POST", apiPath, headers.status, headers, response)
    return nil, errReason
end
