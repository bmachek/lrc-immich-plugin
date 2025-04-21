require "ImmichAPI"

-- Constants
local TITLES = {
    DOWNLOAD_PROGRESS = "Downloading album assets...",
    IMPORT_PROGRESS = "Importing assets into Lightroom...",
    CLEANUP_PROGRESS = "Cleaning up temporary files...",
    SUCCESS_MESSAGE = "All assets have been imported into the catalog.",
    ERROR_NO_ALBUMS = "Failed to load album assets.",
    ERROR_DOWNLOAD = "Failed to download asset: ",
    ERROR_SAVE_FILE = "Failed to save asset to temporary file.",
}

-- Fetch albums from Immich
local function getImmichAlbums()
    local immichAPI = ImmichAPI:new(prefs.url, prefs.apiKey)
    return immichAPI:getAlbumsWODate()
end

-- Download album assets
local function downloadAlbumAssets(immichAPI, albumId)
    local albumAssets = immichAPI:getAlbumAssets(albumId)
    local tempFiles = {}

    if not albumAssets or #albumAssets == 0 then
        LrDialogs.message("Error", TITLES.ERROR_NO_ALBUMS, "critical")
        return tempFiles
    end

    local progressScope = LrProgressScope {
        title = TITLES.DOWNLOAD_PROGRESS,
        caption = "Starting...",
        functionContext = context,
    }

    for i, asset in ipairs(albumAssets) do
        if progressScope:isCanceled() then
            break
        end

        progressScope:setPortionComplete(i, #albumAssets)
        progressScope:setCaption(string.format("Downloading %s (%d of %d)", asset.originalFileName or "asset", i, #albumAssets))

        local assetData = immichAPI:downloadAsset(asset.id)
        if assetData then
            local tempFilePath = LrPathUtils.child(LrPathUtils.getStandardFilePath("temp"), asset.originalFileName)
            local file = io.open(tempFilePath, "wb")
            if file then
                file:write(assetData)
                file:close()
                table.insert(tempFiles, tempFilePath)
            else
                LrDialogs.message("Error", TITLES.ERROR_SAVE_FILE, "critical")
            end
        else
            LrDialogs.message("Error", TITLES.ERROR_DOWNLOAD .. asset.id, "critical")
        end
    end

    progressScope:done()
    return tempFiles
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

-- Get or create a collection
local function getOrCreateCollection(catalog, albumTitle)
    -- Define the parent collection name
    local parentCollectionName = "Immich"
    local collectionName = albumTitle

    local parentCollection
    -- Create the parent collection 
    catalog:withWriteAccessDo("Create Parent Collection", function(context)
        parentCollection = catalog:createCollectionSet(parentCollectionName, nil, true)
    end)


    local childCollection
    -- Create the child collection 
    catalog:withWriteAccessDo("Create Child Collection", function(context)
        childCollection = catalog:createCollection(collectionName, parentCollection, true)
    end)

    return childCollection
end

-- Import assets into Lightroom
local function importAssetsIntoLightroom(catalog, collection, tempFiles)
    local photoList = {}

    catalog:withWriteAccessDo("Import Assets", function(context)
        local progressScope = LrProgressScope {
            title = TITLES.IMPORT_PROGRESS,
            caption = "Preparing import...",
            functionContext = context,
        }

        for i, tempFilePath in ipairs(tempFiles) do
            if progressScope:isCanceled() then
                break
            end

            progressScope:setPortionComplete(i, #tempFiles)
            progressScope:setCaption(string.format("Importing %s (%d of %d)", LrPathUtils.leafName(tempFilePath), i, #tempFiles))

            -- Use a valid destination folder (e.g., the Pictures folder)
            local destinationFolder = LrPathUtils.getStandardFilePath("pictures")
            local destinationPath = LrPathUtils.child(destinationFolder, LrPathUtils.leafName(tempFilePath))

            local success = LrFileUtils.copy(tempFilePath, destinationPath)
            if success then
                local photo = catalog:addPhoto(destinationPath)
                if photo then
                    table.insert(photoList, photo)
                end
            else
                LrDialogs.message("Error", "Failed to copy file to destination folder.", "critical")
            end
        end

        if #photoList > 0 then
            collection:addPhotos(photoList)
        end

        progressScope:done()
    end)
end

-- Clean up temporary files
local function cleanupTemporaryFiles(tempFiles)
    local progressScope = LrProgressScope {
        title = TITLES.CLEANUP_PROGRESS,
        caption = "Starting cleanup...",
        functionContext = context,
    }

    for i, tempFilePath in ipairs(tempFiles) do
        if progressScope:isCanceled() then
            break
        end

        progressScope:setPortionComplete(i, #tempFiles)
        progressScope:setCaption(string.format("Deleting %s (%d of %d)", LrPathUtils.leafName(tempFilePath), i, #tempFiles))

        LrFileUtils.delete(tempFilePath)
    end

    progressScope:done()
end

-- Main function to load album photos
local function doLoadAlbumPhotos(albumId, albumTitle)
    local immichAPI = ImmichAPI:new(prefs.url, prefs.apiKey)
    local catalog = LrApplication.activeCatalog()

    -- Step 1: Download album assets
    local tempFiles = downloadAlbumAssets(immichAPI, albumId)

    -- Step 2: Get or create collection
    local collection = getOrCreateCollection(catalog, albumTitle)

    -- Step 3: Import assets into Lightroom
    if #tempFiles > 0 then
        importAssetsIntoLightroom(catalog, collection, tempFiles)
    end

    -- Step 4: Clean up temporary files
    cleanupTemporaryFiles(tempFiles)

    LrDialogs.message("Success", TITLES.SUCCESS_MESSAGE, "info")
end

-- Async wrapper for loading album photos
local function loadAlbumPhotos(albumId, albumTitle)
    LrTasks.startAsyncTask(function()
        doLoadAlbumPhotos(albumId, albumTitle)
    end)
end

-- Exported functions
return {
    getImmichAlbums = getImmichAlbums,
    loadAlbumPhotos = loadAlbumPhotos,
    getAlbumTitleById = getAlbumTitleById,
}