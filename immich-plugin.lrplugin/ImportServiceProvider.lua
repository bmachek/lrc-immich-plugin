require("ImmichAPI")
require("MetadataTask")
require("AssetStampTask")

-- Constants
local TITLES = {
    DOWNLOAD_PROGRESS = "Downloading album assets...",
    ERROR_NO_ALBUMS = "Failed to load album assets.",
    ERROR_DOWNLOAD = "Failed to download asset: ",
    ERROR_SAVE_FILE = "Failed to save asset to temporary file.",
    ERROR_SEARCH = "Failed to search Immich. Check logs.",
}

-- Fetch albums from Immich
local function getImmichAlbums()
    local immichAPI = ImmichAPI:new(prefs.url, prefs.apiKey)
    return immichAPI:getAlbumsWODate()
end

-- Build a set of Immich asset IDs already present in the catalog so re-import can skip them.
-- Best-effort: any failure returns an empty set (i.e. skip nothing, download everything).
local function getExistingAssetIds()
    local existing = {}
    local ok = LrTasks.pcall(function()
        local catalog = LrApplication.activeCatalog()
        local photos = catalog:findPhotosWithProperty(_PLUGIN, "immichAssetId")
        for _, photo in ipairs(photos or {}) do
            local id = MetadataTask.getImmichAssetId(photo)
            if not Util.nilOrEmpty(id) then
                existing[id] = true
            end
        end
    end)
    if not ok then
        log:warn("getExistingAssetIds: catalog scan failed; not skipping any assets")
        return {}
    end
    return existing
end

-- Download a list of { id, originalFileName } assets into myPath, in configurable-size
-- parallel batches with a cancelable progress bar. Shared by album import and search import.
local function downloadAssets(immichAPI, assets, myPath)
    local progressScope = LrProgressScope({
        title = TITLES.DOWNLOAD_PROGRESS,
        caption = "Starting...",
    })

    -- Skip assets already imported in a previous run (true incremental import).
    local existing = getExistingAssetIds()
    local pathToId = {}
    local skippedExisting = 0
    local toDownload = {}
    for _, asset in ipairs(assets) do
        if existing[asset.id] then
            skippedExisting = skippedExisting + 1
        else
            table.insert(toDownload, asset)
        end
    end

    local completedTasks = 0
    local totalTasks = #toDownload
    local taskQueue = {}

    for _, asset in ipairs(toDownload) do
        if progressScope:isCanceled() then
            break
        end

        -- Queue tasks instead of starting them immediately
        table.insert(taskQueue, function()
            local assetData = immichAPI:downloadAsset(asset.id)
            if assetData then
                local tempFilePath = LrPathUtils.child(myPath, asset.originalFileName)
                local file = io.open(tempFilePath, "wb")

                if file then
                    file:write(assetData)
                    file:close()
                    -- Remember the download path so the imported photo can be stamped later.
                    pathToId[tempFilePath] = asset.id
                else
                    LrDialogs.message("Error", TITLES.ERROR_SAVE_FILE, "critical")
                end

                -- Explicitly free the huge asset string from memory
                assetData = nil -- luacheck: ignore 311
            else
                LrDialogs.message("Error", TITLES.ERROR_DOWNLOAD .. asset.id, "critical")
            end

            if immichAPI:hasLivePhotoVideo(asset.id) then
                local livePhotoVideoId = immichAPI:getLivePhotoVideoId(asset.id)
                if livePhotoVideoId then
                    local livePhotoVideoData = immichAPI:downloadAsset(livePhotoVideoId)
                    if livePhotoVideoData then
                        local tempFilePath = LrPathUtils.child(myPath, immichAPI:getOriginalFileName(livePhotoVideoId))
                        local file = io.open(tempFilePath, "wb")

                        if file then
                            file:write(livePhotoVideoData)
                            file:close()
                        else
                            LrDialogs.message("Error", TITLES.ERROR_SAVE_FILE, "critical")
                        end

                        -- Explicitly free the huge video string from memory
                        livePhotoVideoData = nil -- luacheck: ignore 311
                    else
                        LrDialogs.message("Error", TITLES.ERROR_DOWNLOAD .. livePhotoVideoId, "critical")
                    end
                end
            end

            -- Increment the completed task counter in a thread-safe manner
            completedTasks = completedTasks + 1

            -- Update progress in real-time
            progressScope:setPortionComplete(completedTasks, totalTasks)
            progressScope:setCaption(
                string.format(
                    "Downloading %s (%d of %d)",
                    asset.originalFileName or "asset",
                    completedTasks,
                    totalTasks
                )
            )
        end)
    end

    -- Execute tasks in batches to avoid overwhelming the system.
    -- Batch size is configurable; default to 2 if preference not set or invalid.
    local batchSize = tonumber(prefs.importBatchSize)
    if not batchSize or batchSize < 1 then
        batchSize = 2
    end
    while #taskQueue > 0 do
        local batch = {}
        for i = 1, math.min(batchSize, #taskQueue) do
            table.insert(batch, table.remove(taskQueue, 1))
        end

        -- Run the batch of tasks in parallel
        for _, task in ipairs(batch) do
            LrTasks.startAsyncTask(task)
        end

        -- Wait for the batch to complete
        while completedTasks < totalTasks - #taskQueue do
            LrTasks.sleep(0.1)
        end
    end

    progressScope:done()

    if skippedExisting > 0 then
        log:trace("downloadAssets: skipped " .. skippedExisting .. " asset(s) already in the catalog")
    end

    return pathToId
end

-- Fetch an album's assets and download them into myPath. Returns a { path -> assetId } map.
local function downloadAlbumAssets(immichAPI, albumId, myPath)
    local albumAssets = immichAPI:getAlbumAssets(albumId)

    if not albumAssets or #albumAssets == 0 then
        LrDialogs.message("Error", TITLES.ERROR_NO_ALBUMS, "critical")
        return nil
    end

    return downloadAssets(immichAPI, albumAssets, myPath)
end

-- Ensure prefs.importPath and a named subfolder under it exist; return the subfolder path.
local function prepareImportFolder(subfolderName)
    local importDirectory = prefs.importPath
    if not LrFileUtils.exists(importDirectory) then
        LrFileUtils.createDirectory(importDirectory)
    end

    local myPath = LrPathUtils.child(importDirectory, subfolderName)
    if not LrFileUtils.exists(myPath) then
        LrFileUtils.createDirectory(myPath)
    end

    return myPath
end

-- Turn arbitrary text (e.g. a search query) into a safe folder name.
local function sanitizeFolderName(name)
    local safe = tostring(name or ""):gsub('[/\\:%*%?"<>|]', "_")
    safe = safe:match("^%s*(.-)%s*$") or ""
    if safe == "" then
        safe = "search"
    end
    if #safe > 60 then
        safe = safe:sub(1, 60):match("^%s*(.-)%s*$")
    end
    return safe
end

-- Function to get the album title by albumId
local function getAlbumTitleById(albums, albumId)
    if albums then
        for _, album in ipairs(albums) do
            if album.value == albumId then
                return album.title
            end
        end
    end
    return nil -- Return nil if no matching album is found
end

-- Main function to load album photos
local function loadAlbumPhotos(albumId, albumTitle)
    LrTasks.startAsyncTask(function()
        local immichAPI = ImmichAPI:new(prefs.url, prefs.apiKey)
        local catalog = LrApplication.activeCatalog()

        -- Create parent + album subfolder first. Fix for #66
        local myPath = prepareImportFolder(albumTitle)

        -- Download album assets
        local pathToId = downloadAlbumAssets(immichAPI, albumId, myPath)

        -- Import assets into Lightroom
        catalog:triggerImportUI(myPath)

        -- Stamp the imported photos with their Immich asset IDs once they land in the catalog.
        if pathToId then
            AssetStampTask.pollAfterImport(pathToId)
        end
    end)
end

-- Run a smart (CLIP) search and import the matching assets into Lightroom.
local function loadSearchPhotos(query)
    LrTasks.startAsyncTask(function()
        local immichAPI = ImmichAPI:new(prefs.url, prefs.apiKey)
        local catalog = LrApplication.activeCatalog()

        local searchAssets = immichAPI:searchSmart(query)
        if not searchAssets then
            LrDialogs.message("Error", TITLES.ERROR_SEARCH, "critical")
            return
        end
        if #searchAssets == 0 then
            LrDialogs.message("No results", 'No photos in Immich matched: "' .. query .. '"', "info")
            return
        end

        local myPath = prepareImportFolder(sanitizeFolderName("Search - " .. query))

        local pathToId = downloadAssets(immichAPI, searchAssets, myPath)

        catalog:triggerImportUI(myPath)

        if pathToId then
            AssetStampTask.pollAfterImport(pathToId)
        end
    end)
end

local function showConfigurationDialog()
    log:info("Opening Immich import configuration dialog")
    LrFunctionContext.callWithContext("showConfigurationDialog", function(context)
        -- Create the dialog UI
        local f = LrView.osFactory()
        local bind = LrView.bind
        local share = LrView.share
        local propertyTable = LrBinding.makePropertyTable(context)
        propertyTable.url = ""
        propertyTable.apiKey = ""
        propertyTable.importPath = ""
        propertyTable.importBatchSize = prefs.importBatchSize or 2

        if prefs.url ~= nil then
            propertyTable.url = prefs.url
        end

        if prefs.apiKey ~= nil then
            propertyTable.apiKey = prefs.apiKey
        end

        if prefs.importPath ~= nil then
            propertyTable.importPath = prefs.importPath
        end

        local contents = f:column({
            bind_to_object = propertyTable,
            spacing = f:control_spacing(),
            f:row({
                f:static_text({
                    title = "URL:",
                    alignment = "right",
                    width = share("labelWidth"),
                }),
                f:edit_field({
                    value = bind("url"),
                    truncation = "middle",
                    immediate = false,
                    fill_horizontal = 1,
                    width_in_chars = 28,
                    validate = function(v, url)
                        local sanitizedURL = ImmichAPI:sanityCheckAndFixURL(url)
                        if sanitizedURL == false then
                            return false, url, "URL must not be empty. Example: https://demo.immich.app"
                        end
                        if sanitizedURL == nil then
                            return false, url, "Entered URL not valid.\nShould look like https://demo.immich.app"
                        end
                        if
                            sanitizedURL == url or (type(url) == "string" and sanitizedURL == url:match("^%s*(.-)%s*$"))
                        then
                            return true, sanitizedURL, ""
                        end
                        LrDialogs.message("Entered URL was autocorrected to " .. sanitizedURL)
                        return true, sanitizedURL, ""
                    end,
                }),
                f:push_button({
                    title = "Test connection",
                    action = function(button)
                        LrTasks.startAsyncTask(function()
                            local immich = ImmichAPI:new(propertyTable.url, propertyTable.apiKey)
                            if immich:checkConnectivity() then
                                LrDialogs.message("Connection test successful")
                            else
                                LrDialogs.message("Connection test NOT successful")
                            end
                        end)
                    end,
                }),
            }),

            f:row({
                f:static_text({
                    title = "API Key:",
                    alignment = "right",
                    width = share("labelWidth"),
                    visible = bind("hasNoError"),
                }),
                f:password_field({
                    value = bind("apiKey"),
                    truncation = "middle",
                    immediate = true,
                    fill_horizontal = 1,
                    width_in_chars = 28,
                }),
            }),

            f:row({
                f:static_text({
                    title = "Import Path:",
                    alignment = "right",
                    width = share("labelWidth"),
                }),
                f:edit_field({
                    value = bind("importPath"),
                    truncation = "middle",
                    immediate = false,
                    fill_horizontal = 1,
                    width_in_chars = 28,
                    validate = function(v, path)
                        if path and path ~= "" then
                            if LrFileUtils.exists(path) then
                                return true, path, ""
                            else
                                return false, path, "Selected path does not exist"
                            end
                        end
                        return true, path, ""
                    end,
                }),
                f:push_button({
                    title = "Browse...",
                    action = function(button)
                        local directory = LrDialogs.runOpenPanel({
                            title = "Choose Import Directory",
                            prompt = "Select",
                            canChooseFiles = false,
                            canChooseDirectories = true,
                            canCreateDirectories = true,
                            allowsMultipleSelection = false,
                        })
                        if directory and directory[1] then
                            log:info("User selected import path: " .. directory[1])
                            propertyTable.importPath = directory[1]
                        else
                            log:info("User cancelled folder selection")
                        end
                    end,
                }),
            }),

            f:row({
                f:static_text({
                    title = "Import Batch Size:",
                    alignment = "right",
                    width = share("labelWidth"),
                }),
                f:edit_field({
                    value = bind("importBatchSize"),
                    width_in_chars = 5,
                    immediate = false,
                    validate = function(_, value)
                        local n = tonumber(value)
                        if not n or n < 1 then
                            return false, value, "Batch size must be a positive integer (>= 1)."
                        end
                        return true, tostring(math.floor(n + 0.5)), ""
                    end,
                }),
            }),
        })

        -- Show the dialog
        local result = LrDialogs.presentModalDialog({
            title = "Immich import configuration",
            contents = contents,
            actionVerb = "Save",
            resizable_width = true,
        })

        -- Handle dialog result
        if result == "ok" then
            log:info("User clicked Save on configuration dialog")
            LrTasks.startAsyncTask(function()
                log:info("Testing connection to: " .. propertyTable.url)
                local immich = ImmichAPI:new(propertyTable.url, propertyTable.apiKey)
                if immich:checkConnectivity() then
                    log:info("Connection successful, saving configuration:")
                    log:info("  URL: " .. propertyTable.url)
                    log:info("  Import Path: " .. propertyTable.importPath)
                    prefs.url = propertyTable.url
                    prefs.apiKey = propertyTable.apiKey
                    prefs.importPath = propertyTable.importPath
                    prefs.importBatchSize = tonumber(propertyTable.importBatchSize) or 2
                    log:info("Configuration saved successfully")
                else
                    log:error("Connection test failed for URL: " .. propertyTable.url)
                    ErrorHandler.handleError(
                        "Invalid import configuration. Settings haven't been saved.",
                        "Invalid import configuration, settings not saved to preferences."
                    )
                end
            end)
        else
            log:info("User cancelled configuration dialog")
        end
    end)
end

-- Exported functions
return {
    getImmichAlbums = getImmichAlbums,
    loadAlbumPhotos = loadAlbumPhotos,
    loadSearchPhotos = loadSearchPhotos,
    getAlbumTitleById = getAlbumTitleById,
    showConfigurationDialog = showConfigurationDialog,
}
