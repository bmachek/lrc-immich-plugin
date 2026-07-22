require("ImmichAPI")
require("MetadataTask")
require("AssetStampTask")

--[[
    SyncFromImmichTask – pull metadata from Immich back onto the selected Lightroom photos.

    Photos are matched to Immich assets through the immichAssetId stored by this plugin
    (MetadataTask), so only photos previously uploaded to Immich can be synced. Supported
    fields: favorite -> pick flag, rating -> stars, description -> caption, GPS -> location,
    and Immich face-recognition people -> a "People/<name>" keyword hierarchy (additive).
]]

SyncFromImmichTask = {}

-- Extract the non-empty person names from an Immich asset-info response.
local function collectPeopleNames(assetInfo)
    local names = {}
    if type(assetInfo.people) == "table" then
        for _, person in ipairs(assetInfo.people) do
            if person and type(person.name) == "string" and not Util.nilOrEmpty(person.name) then
                table.insert(names, person.name)
            end
        end
    end
    return names
end

-- options: { favorite, rating, caption, gps, people, overwrite } (all booleans)
function SyncFromImmichTask.run(options)
    LrTasks.startAsyncTask(function()
        -- Flush any pending import stamps first, so freshly imported photos become syncable.
        AssetStampTask.reconcile(false)

        local catalog = LrApplication.activeCatalog()
        local photos = catalog:getTargetPhotos()

        if not photos or #photos == 0 then
            LrDialogs.message("No photos selected", "Select one or more photos to sync from Immich.", "info")
            return
        end

        local immich = ImmichAPI:new(prefs.url, prefs.apiKey)
        if not immich:checkConnectivity() then
            ErrorHandler.handleError(
                "Immich connection not working. Check URL and API key in the import configuration.",
                "SyncFromImmichTask: connectivity check failed"
            )
            return
        end

        -- Phase 1: fetch asset info from Immich (network) and build an apply plan.
        -- Network calls are kept out of the catalog write lock (phase 2) on purpose.
        local progressScope = LrProgressScope({
            title = "Syncing metadata from Immich...",
            caption = "Starting...",
        })

        local plan = {}
        local skippedNoId = 0
        local skippedMissing = 0
        local total = #photos

        for i, photo in ipairs(photos) do
            if progressScope:isCanceled() then
                break
            end

            local assetId = MetadataTask.getImmichAssetId(photo)
            if Util.nilOrEmpty(assetId) then
                skippedNoId = skippedNoId + 1
            else
                local assetInfo = immich:getAssetInfo(assetId)
                if not assetInfo or assetInfo.isTrashed then
                    skippedMissing = skippedMissing + 1
                else
                    table.insert(plan, { photo = photo, assetInfo = assetInfo })
                end
            end

            progressScope:setPortionComplete(i, total)
            progressScope:setCaption(string.format("Reading metadata (%d of %d)", i, total))
        end

        progressScope:done()

        if #plan == 0 then
            LrDialogs.message(
                "Nothing to sync",
                "None of the selected photos have a matching Immich asset. "
                    .. "Only photos previously uploaded to Immich by this plugin can be synced.",
                "info"
            )
            return
        end

        -- Phase 2: apply changes under a single write-access step (one undo entry).
        local overwrite = options.overwrite == true
        local updated = 0
        local peopleParent = nil
        local peopleKeywords = {}

        catalog:withWriteAccessDo("Sync metadata from Immich", function()
            for _, entry in ipairs(plan) do
                local photo = entry.photo
                local assetInfo = entry.assetInfo
                local exif = assetInfo.exifInfo or {}
                local changed = false

                -- Favorite -> pick flag (never unflags; additive by nature).
                if options.favorite and assetInfo.isFavorite then
                    if overwrite or photo:getRawMetadata("pickStatus") == 0 then
                        photo:setRawMetadata("pickStatus", 1)
                        changed = true
                    end
                end

                -- Rating -> stars. Immich uses 0/-1 for "unrated"; only apply 1..5.
                if options.rating and type(exif.rating) == "number" and exif.rating >= 1 then
                    local current = photo:getRawMetadata("rating")
                    if overwrite or current == nil or current == 0 then
                        photo:setRawMetadata("rating", exif.rating)
                        changed = true
                    end
                end

                -- Description -> caption.
                if options.caption and not Util.nilOrEmpty(exif.description) then
                    if overwrite or Util.nilOrEmpty(photo:getFormattedMetadata("caption")) then
                        photo:setRawMetadata("caption", exif.description)
                        changed = true
                    end
                end

                -- GPS -> location.
                if options.gps and type(exif.latitude) == "number" and type(exif.longitude) == "number" then
                    if overwrite or photo:getRawMetadata("gps") == nil then
                        photo:setRawMetadata("gps", { latitude = exif.latitude, longitude = exif.longitude })
                        changed = true
                    end
                end

                -- People -> "People/<name>" keyword hierarchy (additive; policy does not apply).
                if options.people then
                    local names = collectPeopleNames(assetInfo)
                    if #names > 0 then
                        if peopleParent == nil then
                            peopleParent = catalog:createKeyword("People", {}, false, nil, true)
                        end
                        if peopleParent then
                            for _, name in ipairs(names) do
                                local kw = peopleKeywords[name]
                                if not kw then
                                    kw = catalog:createKeyword(name, {}, true, peopleParent, true)
                                    peopleKeywords[name] = kw
                                end
                                if kw then
                                    photo:addKeyword(kw)
                                    changed = true
                                end
                            end
                        end
                    end
                end

                if changed then
                    updated = updated + 1
                end
            end
        end, { timeout = 30 })

        local details = {}
        if skippedNoId > 0 then
            table.insert(details, skippedNoId .. " skipped (not uploaded to Immich).")
        end
        if skippedMissing > 0 then
            table.insert(details, skippedMissing .. " skipped (asset missing or trashed in Immich).")
        end

        LrDialogs.message(
            string.format("Updated %d of %d selected photo(s).", updated, total),
            #details > 0 and table.concat(details, "\n") or nil,
            "info"
        )
    end)
end
