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
    local ok, s = pcall(function() return inspect(t) end)
    if not ok or s == nil then
        return tostring(t)
    end
    local pattern = '(field = "x%-api%-key",%s+value = ")(%w%w%w%w%w%w%w%w%w%w%w)(%w+)(")'
    return s:gsub(pattern, '%1%2...%4')
end

-- Utility function to log errors and show user-facing error message
function util.handleError(logMsg, userErrorMsg)
    local logMessage = (type(logMsg) == "string" and logMsg ~= "") and logMsg or "Unknown error"
    local displayMessage = (type(userErrorMsg) == "string" and userErrorMsg ~= "") and userErrorMsg or logMessage
    if log and log.error then
        log:error(logMessage)
    end
    if LrDialogs and LrDialogs.showError then
        LrDialogs.showError(displayMessage)
    end
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
    local winPath14 = LrPathUtils.getStandardFilePath('home') .. "\\AppData\\Local\\Adobe\\Lightroom\\Logs\\LrClassicLogs\\"
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