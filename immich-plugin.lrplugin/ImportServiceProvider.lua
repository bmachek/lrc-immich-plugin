require "ImmichAPI"

-- Constants
local TITLES = {
    DOWNLOAD_PROGRESS = "Downloading album assets...",
    ERROR_NO_ALBUMS = "Failed to load album assets.",
    ERROR_DOWNLOAD = "Failed to download asset: ",
    ERROR_SAVE_FILE = "Failed to save asset to temporary file.",
}

-- Fetch albums from Immich
local function getImmichAlbums()
    local immichAPI = ImmichAPI:new(prefs.url, prefs.apiKey)
    return immichAPI:getAlbumsWODate()
end

-- Optimized function to download album assets in parallel and update progress in real-time
local function downloadAlbumAssets(immichAPI, albumId, myPath)
    local albumAssets = immichAPI:getAlbumAssets(albumId)

    if not albumAssets or #albumAssets == 0 then
        LrDialogs.message("Error", TITLES.ERROR_NO_ALBUMS, "critical")
        return
    end

    local progressScope = LrProgressScope {
        title = TITLES.DOWNLOAD_PROGRESS,
        caption = "Starting...",
    }

    local completedTasks = 0
    local totalTasks = #albumAssets
    local taskQueue = {}

    for i, asset in ipairs(albumAssets) do
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
                else
                    LrDialogs.message("Error", TITLES.ERROR_SAVE_FILE, "critical")
                end
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
                    else
                        LrDialogs.message("Error", TITLES.ERROR_DOWNLOAD .. livePhotoVideoId, "critical")
                    end
                end
            end

            -- Increment the completed task counter in a thread-safe manner
            completedTasks = completedTasks + 1

            -- Update progress in real-time
            progressScope:setPortionComplete(completedTasks, totalTasks)
            progressScope:setCaption(string.format("Downloading %s (%d of %d)", asset.originalFileName or "asset", completedTasks, totalTasks))
        end)
    end

    -- Execute tasks in batches to avoid overwhelming the system
    local batchSize = 5 -- Adjust batch size as needed
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
    
        -- Create parent directory first. Fix for #66
        local importDirectory = prefs.importPath
        if not LrFileUtils.exists(importDirectory) then
            LrFileUtils.createDirectory(importDirectory)
        end

        local myPath = LrPathUtils.child(importDirectory, albumTitle)
        if not LrFileUtils.exists(myPath) then
            LrFileUtils.createDirectory(myPath)
        end
    
        -- Download album assets
        downloadAlbumAssets(immichAPI, albumId, myPath)
    
        -- Import assets into Lightroom
        catalog:triggerImportUI(myPath)

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

        if prefs.url ~= nil then
            propertyTable.url = prefs.url
        end

        if prefs.apiKey ~= nil then
            propertyTable.apiKey = prefs.apiKey
        end

        if prefs.importPath ~= nil then
            propertyTable.importPath = prefs.importPath
        end

    local contents = f:column {
        bind_to_object = propertyTable,
        spacing = f:control_spacing(),
        f:row {
            f:static_text {
                title = "URL:",
                alignment = 'right',
                width = share 'labelWidth'
            },
            f:edit_field {
                value = bind 'url',
                truncation = 'middle',
                immediate = false,
                fill_horizontal = 1,
                width_in_chars = 28,
                validate = function (v, url)
                    local sanitizedURL = ImmichAPI:sanityCheckAndFixURL(url)
                    if sanitizedURL == url then
                        return true, url, ''
                    elseif not (sanitizedURL == nil) then
                        LrDialogs.message('Entered URL was autocorrected to ' .. sanitizedURL)
                        return true, sanitizedURL, ''
                    end
                    return false, url, 'Entered URL not valid.\nShould look like https://demo.immich.app'
                end,
            },
            f:push_button {
                title = 'Test connection',
                action = function(button)
                    LrTasks.startAsyncTask(function()
                        local immich = ImmichAPI:new(propertyTable.url, propertyTable.apiKey)
                        if immich:checkConnectivity() then
                            LrDialogs.message('Connection test successful')
                        else
                            LrDialogs.message('Connection test NOT successful')
                        end
                    end)
                end,
            },
        },

        f:row {
            f:static_text {
                title = "API Key:",
                alignment = 'right',
                width = share 'labelWidth',
                visible = bind 'hasNoError',
            },
            f:password_field {
                value = bind 'apiKey',
                truncation = 'middle',
                immediate = true,
                fill_horizontal = 1,
                width_in_chars = 28,
            },
        },

        f:row {
            f:static_text {
                title = "Import Path:",
                alignment = 'right',
                width = share 'labelWidth',
            },
            f:edit_field {
                value = bind 'importPath',
                truncation = 'middle',
                immediate = false,
                fill_horizontal = 1,
                width_in_chars = 28,
                validate = function (v, path)
                    if path and path ~= "" then
                        if LrFileUtils.exists(path) then
                            return true, path, ''
                        else
                            return false, path, 'Selected path does not exist'
                        end
                    end
                    return true, path, ''
                end,
            },
            f:push_button {
                title = 'Browse...',
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
            },
        }
    }

    -- Show the dialog
    local result = LrDialogs.presentModalDialog {
        title = "Immich import configuration",
        contents = contents,
        actionVerb = "Save",
        resizable_width = true,
    }

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
                log:info("Configuration saved successfully")
            else
                log:error("Connection test failed for URL: " .. propertyTable.url)
                util.handleError("Invalid import configuration, settings not saved to preferences.", "Invalid import configuration. Settings haven't been saved.")
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
    getAlbumTitleById = getAlbumTitleById,
    showConfigurationDialog = showConfigurationDialog,
}