-- Helper functions

util = {}

-- Utility function to check if table contains a value
function util.table_contains(tbl, x)
    if type(tbl) ~= "table" then
        return false
    end
    local found = false
    for _, v in pairs(tbl) do
        if v == x then
            found = true
            break
        end
    end
    return found
end

-- Utility function to dump tables as JSON scrambling the API key.
function util.dumpTable(t)
    if t == nil then
        return "nil"
    end
    local ok, s = LrTasks.pcall(function() return inspect(t) end)
    if not ok or s == nil then
        return tostring(t)
    end
    local pattern = '(field = "x%-api%-key",%s+value = ")(%w%w%w%w%w%w%w%w%w%w%w)(%w+)(")'
    return s:gsub(pattern, '%1%2...%4')
end

-- Check if val is empty or nil
-- Taken from https://github.com/midzelis/mi.Immich.Publisher/blob/main/utils.lua
local function trim(s)
    return s:match("^%s*(.-)%s*$")
end

-- Taken from https://github.com/midzelis/mi.Immich.Publisher/blob/main/utils.lua
function util.nilOrEmpty(val)
    if type(val) == 'string' then
        return val == nil or trim(val) == ''
    else
        return val == nil
    end
end

-- Get lowercase file extension from path (e.g. "photo.dng" -> "dng")
function util.getExtension(path)
    if not path or type(path) ~= "string" then return "" end
    return string.lower(string.match(path, "%.([^%.]+)$") or "")
end

function util.cutApiKey(key)
    if key == nil or type(key) ~= "string" then
        return "(no key)"
    end
    if key == "" then
        return "(empty key)"
    end
    if #key <= 20 then
        return string.sub(key, 1, 8) .. "..."
    end
    return string.sub(key, 1, 20) .. '...'
end

function util.getLogfilePath()
    local filename = "ImmichPlugin.log"
    local macPath14 = LrPathUtils.getStandardFilePath('home') .. "/Library/Logs/Adobe/Lightroom/LrClassicLogs/"
    local winPath14 = LrPathUtils.getStandardFilePath('home') ..
    "\\AppData\\Local\\Adobe\\Lightroom\\Logs\\LrClassicLogs\\"
    local macPathOld = LrPathUtils.getStandardFilePath('documents') .. "/LrClassicLogs/"
    local winPathOld = LrPathUtils.getStandardFilePath('documents') .. "\\LrClassicLogs\\"

    local lightroomVersion = LrApplication.versionTable()

    if lightroomVersion.major >= 14 then
        if MAC_ENV then
            return macPath14 .. filename
        else
            return winPath14 .. filename
        end
    else
        if MAC_ENV then
            return macPathOld .. filename
        else
            return winPathOld .. filename
        end
    end
end

-- Get photo UUID for use as deviceAssetId
-- UUIDs are stable and don't change when photos are reimported
-- Falls back to localIdentifier if UUID is not available (for backward compatibility)
function util.getPhotoDeviceId(photo)
    if not photo then
        return nil
    end

    -- Try to get UUID first (preferred, stable identifier)
    local uuid = photo:getRawMetadata("uuid")
    if uuid and uuid ~= "" then
        return tostring(uuid)
    end

    -- Fallback to localIdentifier for backward compatibility
    -- This handles cases where UUID might not be available
    if photo.localIdentifier then
        log:trace("Photo UUID not available, using localIdentifier: " .. tostring(photo.localIdentifier))
        return tostring(photo.localIdentifier)
    end

    log:warn("Neither UUID nor localIdentifier available for photo")
    return nil
end

-- Shared by Export and Publish: validate export context and connect to Immich.
-- contextLabel: "Export" or "Publish" (used in error messages and task name).
-- Returns: exportSession, exportParams, immich or nil.
function util.validateExportContextAndConnect(exportContext, contextLabel)
    if not exportContext or not exportContext.exportSession or not exportContext.propertyTable then
        ErrorHandler.handleError('Export context is missing. Please try again.',
            (contextLabel or "Export") .. "Task: invalid export context")
        return nil
    end
    local exportSession = exportContext.exportSession
    local exportParams = exportContext.propertyTable
    local settingsText = (contextLabel == "Publish") and "plugin settings" or "export settings"
    if util.nilOrEmpty(exportParams.url) or util.nilOrEmpty(exportParams.apiKey) then
        ErrorHandler.handleError('Configure Immich URL and API key in the ' .. settingsText .. '.',
            (contextLabel or "Export") .. "Task: URL or API key not set")
        return nil
    end
    local immich = ImmichAPI:new(exportParams.url, exportParams.apiKey)
    if not immich:checkConnectivity() then
        ErrorHandler.handleError('Immich connection not working. Check URL and API key in ' .. settingsText .. '.',
            'Immich connection not working, probably due to wrong url and/or apiKey. Export stopped.')
        return nil
    end
    return exportSession, exportParams, immich
end

-- Shared: build a simple progress title, e.g. "Publishing 5 photos to Immich".
function util.buildSimpleUploadProgressTitle(nPhotos, verb, suffix)
    local countStr = (nPhotos > 1) and (nPhotos .. " photos") or "one photo"
    return verb .. " " .. countStr .. " to " .. (suffix or "Immich")
end

-- Shared: show failure and stack-warning dialogs after upload.
function util.reportUploadFailuresAndWarnings(failures, stackWarnings)
    if failures and #failures > 0 then
        local message = (#failures == 1) and "1 file failed to upload correctly." or
        (tostring(#failures) .. " files failed to upload correctly.")
        local formattedFailures = {}
        for i = 1, math.min(#failures, 20) do
            table.insert(formattedFailures, "• " .. failures[i])
        end
        if #failures > 20 then
            table.insert(formattedFailures, "... and " .. tostring(#failures - 20) .. " more failures.")
            table.insert(formattedFailures, "(Check ImmichPlugin.log for full details)")
        end
        LrDialogs.message(message, table.concat(formattedFailures, "\n"), "critical")
    end
    if stackWarnings and #stackWarnings > 0 then
        local message = (#stackWarnings == 1) and "1 photo had stacking issues (uploaded without stack):" or
        (tostring(#stackWarnings) .. " photos had stacking issues (uploaded without stacks):")
        local formattedWarnings = {}
        for i = 1, math.min(#stackWarnings, 20) do
            table.insert(formattedWarnings, "• " .. stackWarnings[i])
        end
        if #stackWarnings > 20 then
            table.insert(formattedWarnings, "... and " .. tostring(#stackWarnings - 20) .. " more warnings.")
            table.insert(formattedWarnings, "(Check ImmichPlugin.log for full details)")
        end
        LrDialogs.message(message, table.concat(formattedWarnings, "\n"), "warning")
    end
end
