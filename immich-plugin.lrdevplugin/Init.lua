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
-- _G.LrCatalog = import 'LrCatalog'
_G.prefs = _G.LrPrefs.prefsForPlugin()
_G.JSON = require "JSON"
_G.inspect = require 'inspect'
_G.log = import 'LrLogger'('ImmichPlugin')
_G.log:enable('logfile')

require "util"
