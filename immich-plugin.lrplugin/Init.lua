---@diagnostic disable: undefined-global

-- Global imports
_G.LrHttp = import 'LrHttp'
_G.LrDate = import 'LrDate'
_G.LrPathUtils = import 'LrPathUtils'
_G.LrFileUtils = import 'LrFileUtils'
_G.LrTasks = import 'LrTasks'
_G.LrErrors = import 'LrErrors'
_G.LrDialogs = import 'LrDialogs'
_G.LrView = import 'LrView'
_G.LrBinding = import 'LrBinding'
_G.LrColor = import 'LrColor'
_G.LrFunctionContext = import 'LrFunctionContext'
_G.LrApplication = import 'LrApplication'
_G.LrPrefs = import 'LrPrefs'
_G.LrShell = import 'LrShell'
_G.LrSystemInfo = import 'LrSystemInfo'
_G.LrProgressScope = import 'LrProgressScope'
_G.LrLogger = import 'LrLogger'

_G.JSON = require "JSON"
_G.inspect = require 'inspect'
require "util"
require "ErrorHandler"

-- Global initializations
_G.prefs = _G.LrPrefs.prefsForPlugin()
_G.log = import 'LrLogger' ('ImmichPlugin')
if _G.prefs.logging == nil then
    _G.prefs.logging = false
end
if _G.prefs.logging then
    _G.log:enable('logfile')
else
    _G.log:disable()
end

if _G.prefs.apiKey == nil then _G.prefs.apiKey = '' end
if _G.prefs.url == nil then _G.prefs.url = '' end
if _G.prefs.importPath == nil then _G.prefs.importPath = LrPathUtils.child(LrPathUtils.getStandardFilePath("pictures"), "Immich Import") end
