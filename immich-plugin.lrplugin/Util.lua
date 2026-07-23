-- Helper functions

Util = {}

-- Utility function to check if table contains a value
function Util.table_contains(tbl, x)
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
function Util.dumpTable(t)
    if t == nil then
        return "nil"
    end
    local ok, s = LrTasks.pcall(function()
        return inspect(t)
    end)
    if not ok or s == nil then
        return tostring(t)
    end
    local pattern = '(field = "x%-api%-key",%s+value = ")(%w%w%w%w%w%w%w%w%w%w%w)(%w+)(")'
    return s:gsub(pattern, "%1%2...%4")
end

-- Check if val is empty or nil
-- Taken from https://github.com/midzelis/mi.Immich.Publisher/blob/main/utils.lua
local function trim(s)
    return s:match("^%s*(.-)%s*$")
end

-- Taken from https://github.com/midzelis/mi.Immich.Publisher/blob/main/utils.lua
function Util.nilOrEmpty(val)
    if type(val) == "string" then
        return val == nil or trim(val) == ""
    else
        return val == nil
    end
end

-- Quote a single argument for a shell command line. On Windows, LrTasks.execute runs the
-- string through cmd.exe, which uses double quotes; elsewhere (macOS) it goes through
-- /bin/sh, which uses single quotes. Used to build curl commands with untrusted values
-- (paths, API keys, URLs) safely.
function Util.shellQuote(arg)
    arg = tostring(arg or "")
    if WIN_ENV then
        -- cmd.exe: wrap in double quotes and escape embedded double quotes.
        return '"' .. arg:gsub('"', '""') .. '"'
    end
    -- POSIX sh: wrap in single quotes; close-escape-reopen any embedded single quote.
    return "'" .. arg:gsub("'", "'\\''") .. "'"
end

-- Get lowercase file extension from path (e.g. "photo.dng" -> "dng")
function Util.getExtension(path)
    if not path or type(path) ~= "string" then
        return ""
    end
    return string.lower(string.match(path, "%.([^%.]+)$") or "")
end

-- Convert a Lightroom (Cocoa) timestamp to an ISO 8601 string with a timezone
-- offset. LrDate.timeToW3CDate emits local time without a zone (e.g.
-- "2026-07-24T07:41:39"), which Immich's validator rejects; append the local
-- UTC offset (or "Z") so the string matches the expected ISO 8601 format.
function Util.toISO8601(cocoaTime)
    local base = LrDate.timeToW3CDate(cocoaTime)
    local tz = os.date("%z")
    local sign, hh, mm = tostring(tz):match("([%+%-])(%d%d)(%d%d)")
    if sign then
        return base .. sign .. hh .. ":" .. mm
    end
    return base .. "Z"
end

function Util.cutApiKey(key)
    if key == nil or type(key) ~= "string" then
        return "(no key)"
    end
    if key == "" then
        return "(empty key)"
    end
    if #key <= 20 then
        return string.sub(key, 1, 8) .. "..."
    end
    return string.sub(key, 1, 20) .. "..."
end

function Util.getLogfilePath()
    local filename = "ImmichPlugin.log"
    local macPath14 = LrPathUtils.getStandardFilePath("home") .. "/Library/Logs/Adobe/Lightroom/LrClassicLogs/"
    local winPath14 = LrPathUtils.getStandardFilePath("home")
        .. "\\AppData\\Local\\Adobe\\Lightroom\\Logs\\LrClassicLogs\\"
    local macPathOld = LrPathUtils.getStandardFilePath("documents") .. "/LrClassicLogs/"
    local winPathOld = LrPathUtils.getStandardFilePath("documents") .. "\\LrClassicLogs\\"

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

-- Returns true if a global Immich connection (URL + API key) is configured.
-- Otherwise shows a message directing the user to the Plugin Manager and returns
-- false. Used by the Library/Help menu tasks (Import, Sync, Search, Share links).
function Util.ensureConnected()
    if Util.nilOrEmpty(prefs.url) or Util.nilOrEmpty(prefs.apiKey) then
        LrDialogs.message(
            "Immich is not configured yet.",
            "Set the Immich server URL and API key in the Plug-in Manager"
                .. " (File → Plug-in Manager → Immich) and try again.",
            "info"
        )
        return false
    end
    return true
end

-- Resolve the effective Immich URL/API key for an export or publish preset.
-- When the preset opts into the global (plugin-wide) connection, use the shared
-- prefs configured in Plugin Manager; otherwise use the preset's own values.
-- Returns: url, apiKey.
function Util.resolveConnection(settings)
    if settings and settings.useGlobalConnection then
        return prefs.url, prefs.apiKey
    end
    if settings then
        return settings.url, settings.apiKey
    end
    return nil, nil
end

-- Shared by Export and Publish: validate export context and connect to Immich.
-- contextLabel: "Export" or "Publish" (used in error messages and task name).
-- Returns: exportSession, exportParams, immich or nil.
function Util.validateExportContextAndConnect(exportContext, contextLabel)
    if not exportContext or not exportContext.exportSession or not exportContext.propertyTable then
        ErrorHandler.handleError(
            "Export context is missing. Please try again.",
            (contextLabel or "Export") .. "Task: invalid export context"
        )
        return nil
    end
    local exportSession = exportContext.exportSession
    local exportParams = exportContext.propertyTable
    local url, apiKey = Util.resolveConnection(exportParams)
    local settingsText = exportParams.useGlobalConnection and "the plugin manager (global connection)"
        or ((contextLabel == "Publish") and "plugin settings" or "export settings")
    if Util.nilOrEmpty(url) or Util.nilOrEmpty(apiKey) then
        ErrorHandler.handleError(
            "Configure Immich URL and API key in " .. settingsText .. ".",
            (contextLabel or "Export") .. "Task: URL or API key not set"
        )
        return nil
    end
    local immich = ImmichAPI:new(url, apiKey)
    if not immich:checkConnectivity() then
        ErrorHandler.handleError(
            "Immich connection not working. Check URL and API key in " .. settingsText .. ".",
            "Immich connection not working, probably due to wrong url and/or apiKey. Export stopped."
        )
        return nil
    end
    return exportSession, exportParams, immich
end

-- Shared: build a simple progress title, e.g. "Publishing 5 photos to Immich".
function Util.buildSimpleUploadProgressTitle(nPhotos, verb, suffix)
    local countStr = (nPhotos > 1) and (nPhotos .. " photos") or "one photo"
    return verb .. " " .. countStr .. " to " .. (suffix or "Immich")
end

-- Shared: show failure and stack-warning dialogs after upload.
function Util.reportUploadFailuresAndWarnings(failures, stackWarnings)
    if failures and #failures > 0 then
        local message = (#failures == 1) and "1 file failed to upload correctly."
            or (tostring(#failures) .. " files failed to upload correctly.")
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
        local message = (#stackWarnings == 1) and "1 photo had stacking issues (uploaded without stack):"
            or (tostring(#stackWarnings) .. " photos had stacking issues (uploaded without stacks):")
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
