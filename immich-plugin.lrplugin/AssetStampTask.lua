require("MetadataTask")

--[[
    AssetStampTask – stamp the Immich asset ID onto photos imported *from* Immich.

    Import hands off to Lightroom's interactive Import UI (catalog:triggerImportUI), which is
    non-blocking and user-driven, so the imported LrPhoto handles are not available at download
    time. Instead, downloads register a { downloadPath -> assetId } map here; reconcile() later
    matches each pending path to a catalog photo via findPhotoByPath and stamps it.

    Path matching succeeds when photos are Added in place from the import folder (the common
    workflow). Copy/Move imports relocate the file, so those cannot be matched by path and are
    dropped after STALE_SECONDS to keep the pending registry bounded.

    Stamping imported photos lets the Sync-from-Immich and share-link actions work on them, and
    lets re-import skip assets already present in the catalog.
]]

AssetStampTask = {}

local PREF_KEY = "pendingAssetStamps"
local STALE_SECONDS = 7 * 86400

-- LrPrefs only persists table values when the table is reassigned, so callers that mutate the
-- pending registry must write it back through these helpers.
local function loadPending()
    local pending = prefs[PREF_KEY]
    if type(pending) ~= "table" then
        return {}
    end
    return pending
end

local function savePending(pending)
    if pending == nil or next(pending) == nil then
        prefs[PREF_KEY] = nil
    else
        prefs[PREF_KEY] = pending
    end
end

-- Accept both the current { id, ts } entry shape and a bare id string (defensive).
local function entryId(entry)
    if type(entry) == "table" then
        return entry.id
    end
    return entry
end

local function entryTs(entry)
    if type(entry) == "table" and type(entry.ts) == "number" then
        return entry.ts
    end
    return 0
end

-- Merge a { downloadPath -> assetId } map into the persisted pending registry.
function AssetStampTask.registerPending(map)
    if type(map) ~= "table" then
        return
    end
    local pending = loadPending()
    local now = LrDate.currentTime()
    local added = 0
    for path, id in pairs(map) do
        if not Util.nilOrEmpty(path) and not Util.nilOrEmpty(id) then
            pending[path] = { id = tostring(id), ts = now }
            added = added + 1
        end
    end
    if added > 0 then
        savePending(pending)
        log:trace("AssetStampTask.registerPending: registered " .. added .. " pending stamp(s)")
    end
end

-- Stamp any pending imports whose files are now present in the catalog (matched by path).
-- Drops entries that can no longer be matched (moved on import) once they age past STALE_SECONDS.
-- verbose=true shows a summary dialog. Returns the number of photos stamped.
function AssetStampTask.reconcile(verbose)
    local pending = prefs[PREF_KEY]
    if type(pending) ~= "table" or next(pending) == nil then
        if verbose then
            LrDialogs.message("Nothing to reconcile", "No imported photos are awaiting an Immich asset ID.", "info")
        end
        return 0
    end

    local catalog = LrApplication.activeCatalog()
    local toStamp = {}
    local remaining = {}
    local dropped = 0
    local now = LrDate.currentTime()

    for path, entry in pairs(pending) do
        local id = entryId(entry)
        local photo = catalog:findPhotoByPath(path)
        if photo and not Util.nilOrEmpty(id) then
            table.insert(toStamp, { photo = photo, id = id })
        elseif (now - entryTs(entry)) > STALE_SECONDS or Util.nilOrEmpty(id) then
            -- Aged out (likely a Copy/Move import that cannot be matched by path), or invalid.
            dropped = dropped + 1
        else
            remaining[path] = entry
        end
    end

    -- setImmichAssetId opens its own private write-access transaction per photo, so no outer
    -- write gate is needed here (and nesting write access would be wrong).
    local stamped = 0
    for _, e in ipairs(toStamp) do
        if Util.nilOrEmpty(MetadataTask.getImmichAssetId(e.photo)) then
            if MetadataTask.setImmichAssetId(e.photo, e.id) then
                stamped = stamped + 1
            end
        end
    end

    savePending(remaining)
    log:trace(
        "AssetStampTask.reconcile: stamped "
            .. stamped
            .. ", dropped "
            .. dropped
            .. ", still pending "
            .. tostring(next(remaining) ~= nil)
    )

    if verbose then
        local details = {}
        if next(remaining) ~= nil then
            table.insert(details, "Some imports are still pending (not yet in the catalog).")
        end
        if dropped > 0 then
            table.insert(details, dropped .. " could not be matched (imported to a different path) and were dropped.")
        end
        LrDialogs.message(
            string.format("Stamped %d imported photo(s) with their Immich asset ID.", stamped),
            #details > 0 and table.concat(details, "\n") or nil,
            "info"
        )
    end

    return stamped
end

-- Register a fresh { path -> id } map, then poll reconcile a few times so quick Add-in-place
-- imports get stamped automatically. Whatever is left stays persisted for later reconcile.
function AssetStampTask.pollAfterImport(map)
    AssetStampTask.registerPending(map)
    LrTasks.startAsyncTask(function()
        for _ = 1, 12 do
            LrTasks.sleep(5)
            local pending = prefs[PREF_KEY]
            if type(pending) ~= "table" or next(pending) == nil then
                break
            end
            AssetStampTask.reconcile(false)
        end
    end)
end
