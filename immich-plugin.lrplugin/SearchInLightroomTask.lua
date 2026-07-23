require("ImmichAPI")
require("MetadataTask")
require("AssetStampTask")

--[[
    SearchInLightroomTask – run Immich CLIP/smart search and select the matching
    photos inside the Lightroom catalog.

    Photos are matched to Immich assets through the immichAssetId stored by this
    plugin (MetadataTask), so only photos previously exported/published to Immich
    can be found. The matched photos are selected in the catalog (with All
    Photographs as the active source) so the user can act on them.
]]

SearchInLightroomTask = {}

-- Build a tidy collection name from a raw search query: collapse whitespace, drop the
-- "/" hierarchy separator, and cap the length so long queries stay usable in the UI.
local function buildCollectionName(query)
    local name = tostring(query or "")
    name = name:gsub("%s+", " ")
    name = name:gsub("/", "-")
    name = Util.trim and Util.trim(name) or name:gsub("^%s+", ""):gsub("%s+$", "")
    if #name > 60 then
        name = name:sub(1, 57) .. "..."
    end
    if Util.nilOrEmpty(name) then
        name = "Search"
    end
    return name
end

-- options: { query = string } (query is required)
function SearchInLightroomTask.run(options)
    LrTasks.startAsyncTask(function()
        local query = options and options.query
        if Util.nilOrEmpty(query) then
            LrDialogs.message("Please enter a search query.", nil, "warning")
            return
        end

        -- Flush any pending import stamps first, so freshly imported photos become findable.
        AssetStampTask.reconcile(false)

        local catalog = LrApplication.activeCatalog()

        local immich = ImmichAPI:new(prefs.url, prefs.apiKey)
        if not immich:checkConnectivity() then
            ErrorHandler.handleError(
                "Immich connection not working. Check URL and API key in the import configuration.",
                "SearchInLightroomTask: connectivity check failed"
            )
            return
        end

        local progressScope = LrProgressScope({
            title = "Searching Immich...",
            caption = 'Searching for "' .. query .. '"',
        })

        -- Phase 1: ask Immich which assets match the query.
        local searchAssets = immich:searchSmart(query)
        if not searchAssets then
            progressScope:done()
            ErrorHandler.handleError(
                "Immich smart search failed. Check logs.",
                "SearchInLightroomTask: searchSmart returned nil"
            )
            return
        end
        if #searchAssets == 0 then
            progressScope:done()
            LrDialogs.message("No results", 'No photos in Immich matched: "' .. query .. '"', "info")
            return
        end

        -- Set of Immich asset IDs that matched the query.
        local matchedIds = {}
        for _, asset in ipairs(searchAssets) do
            if asset.id then
                matchedIds[tostring(asset.id)] = true
            end
        end

        -- Phase 2: map stored Immich asset IDs back to local Lightroom photos.
        -- findPhotosWithProperty returns only photos this plugin has stamped, so we
        -- never scan the whole catalog.
        progressScope:setCaption("Matching against Lightroom catalog...")
        local found = {}
        local ok = LrTasks.pcall(function()
            local stampedPhotos = catalog:findPhotosWithProperty(_PLUGIN, "immichAssetId")
            for _, photo in ipairs(stampedPhotos or {}) do
                local assetId = MetadataTask.getImmichAssetId(photo)
                if not Util.nilOrEmpty(assetId) and matchedIds[tostring(assetId)] then
                    table.insert(found, photo)
                end
            end
        end)
        if not ok then
            progressScope:done()
            ErrorHandler.handleError(
                "Failed to scan the Lightroom catalog. Check logs.",
                "SearchInLightroomTask: findPhotosWithProperty failed"
            )
            return
        end

        progressScope:done()

        if #found == 0 then
            LrDialogs.message(
                "No matches in catalog",
                string.format(
                    '%d photo(s) in Immich matched "%s", but none of them exist in this Lightroom '
                        .. "catalog as photos previously exported/published to Immich by this plugin.",
                    #searchAssets,
                    query
                ),
                "info"
            )
            return
        end

        -- Phase 3: gather the matches into a collection named after the query, under an
        -- "Immich search results" collection set. Re-running the same query refreshes the
        -- collection's contents rather than piling up duplicates.
        local collection
        local collectionName = buildCollectionName(query)
        local wrote = LrTasks.pcall(function()
            catalog:withWriteAccessDo("Immich search: " .. collectionName, function()
                local set = catalog:createCollectionSet("Immich search results", nil, true)
                collection = catalog:createCollection(collectionName, set, true)
                if collection then
                    local existing = collection:getPhotos()
                    if existing and #existing > 0 then
                        collection:removePhotos(existing)
                    end
                    collection:addPhotos(found)
                end
            end, { timeout = 30 })
        end)

        if not wrote or not collection then
            ErrorHandler.handleError(
                "Failed to create the search results collection. Check logs.",
                "SearchInLightroomTask: collection creation failed"
            )
            return
        end

        -- Reveal the collection so the user lands on the results.
        catalog:setActiveSources({ collection })
        catalog:setSelectedPhotos(found[1], found)

        local skipped = #searchAssets - #found
        local info = string.format(
            'Added %d of %d Immich match(es) for "%s" to collection "%s".',
            #found, #searchAssets, query, collectionName
        )
        if skipped > 0 then
            info = info .. "\n" .. skipped .. " match(es) are not in this catalog (or were not exported by this plugin)."
        end
        LrDialogs.showBezel(string.format('%d photo(s) → "%s"', #found, collectionName))
        log:trace("SearchInLightroomTask: " .. info)
    end)
end
