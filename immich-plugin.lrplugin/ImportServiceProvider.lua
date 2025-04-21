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
    
        local myPath = LrPathUtils.child(LrPathUtils.child(LrPathUtils.getStandardFilePath("pictures"), "Immich Import"),albumTitle)
        if not LrFileUtils.exists(myPath) then
            LrFileUtils.createDirectory(myPath)
        end
    
        -- Download album assets
        downloadAlbumAssets(immichAPI, albumId, myPath)
    
        -- Import assets into Lightroom
        catalog:triggerImportUI(myPath)
    end)
end

-- Exported functions
return {
    getImmichAlbums = getImmichAlbums,
    loadAlbumPhotos = loadAlbumPhotos,
    getAlbumTitleById = getAlbumTitleById,
}