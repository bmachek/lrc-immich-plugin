require "ImmichAPI"

local function getImmichAlbums()
    local immichAPI = ImmichAPI:new(prefs.url, prefs.apiKey)
    return immichAPI:getAlbumsWODate()   
end

local function downloadAlbumAssets(immichAPI, albumId)
    local albumAssets = immichAPI:getAlbumAssets(albumId)
    local tempFiles = {}

    if albumAssets then
        local progressScope = LrProgressScope {
            title = "Downloading album assets...",
            caption = "Starting...",
            functionContext = context -- assuming you're in an LrTasks.startAsyncTask with a context
        }

        for i = 1, #albumAssets do

            local asset = albumAssets[i]
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
                    LrDialogs.message("Error", "Failed to save asset to temporary file.", "critical")
                end
            else
                LrDialogs.message("Error", "Failed to download asset: " .. asset.id, "critical")
            end
        end

        progressScope:done()
    else
        LrDialogs.message("Error", "Failed to load album assets.", "critical")
    end

    return tempFiles
end

local function getOrCreateCollection(catalog, immichAPI, albumId)
    local albums = immichAPI:getAlbumsWODate()
    local collectionName = "Immich - Album ID " .. tostring(albumId)

    if albums then
        for _, album in ipairs(albums) do
            if album.value == albumId then
                collectionName = "Immich - " .. album.title
                break
            end
        end
    end

    -- Check if collection already exists
    local collection
    for _, col in ipairs(catalog:getChildCollections()) do
        if col:getName() == collectionName then
            collection = col
            break
        end
    end

    if not collection then
        catalog:withWriteAccessDo("Create Collection", function(context)
            collection = catalog:createCollection(collectionName, nil, true)
        end)
    end

    return collection
end

local function importAssetsIntoLightroom(catalog, collection, albumId, tempFiles)
    local photoList = {}

    catalog:withWriteAccessDo("Import Assets", function(context)
        local progressScope = LrProgressScope {
            title = "Importing assets into Lightroom",
            caption = "Preparing import...",
            functionContext = context
        }

        

        -- Import and collect photos with progress
        for i, tempFilePath in ipairs(tempFiles) do

            progressScope:setPortionComplete(i, #tempFiles)
            progressScope:setCaption(string.format("Importing %s (%d of %d)", LrPathUtils.leafName(tempFilePath), i, #tempFiles))

            local photo = catalog:addPhoto(tempFilePath)
            if photo then
                table.insert(photoList, photo)
            end
        end

        if #photoList > 0 then
            collection:addPhotos(photoList)
        end

        progressScope:done()
    end)

end

local function cleanupTemporaryFiles(tempFiles, context)
    local progressScope = LrProgressScope {
        title = "Cleaning up temporary files...",
        caption = "Starting cleanup...",
        functionContext = context
    }

    for i, tempFilePath in ipairs(tempFiles) do

        progressScope:setPortionComplete(i, #tempFiles)
        progressScope:setCaption(string.format("Deleting %s (%d of %d)", LrPathUtils.leafName(tempFilePath), i, #tempFiles))

        LrFileUtils.delete(tempFilePath)
    end

    progressScope:done()
end

local function doLoadAlbumPhotos(albumId)
    local immichAPI = ImmichAPI:new(prefs.url, prefs.apiKey)
    local catalog = LrApplication.activeCatalog()

    -- Step 1: Download album assets
    local tempFiles = downloadAlbumAssets(immichAPI, albumId)

    -- Step 3: Get or create collection
    local collection = getOrCreateCollection(catalog, immichAPI, albumId)

    -- Step 3: Import assets into Lightroom
    if #tempFiles > 0 then
        importAssetsIntoLightroom(catalog, collection, albumId, tempFiles)
    end

    -- Step 4: Clean up temporary files
    cleanupTemporaryFiles(tempFiles, context)

    LrDialogs.message("Success", "All assets have been imported into the catalog.", "info")
end

local function loadAlbumPhotos(albumId)
    LrTasks.startAsyncTask(function()
        doLoadAlbumPhotos(albumId)
    end)
end

return {
    getImmichAlbums = getImmichAlbums,
    loadAlbumPhotos = loadAlbumPhotos,
}