-- ImmichUpload plug-in
require "ImmichUploadInfoDialogSections"
local prefs = import 'LrPrefs'.prefsForPlugin() 


return {
	
	sectionsForTopOfDialog = ImmichUploadInfoDialogSections.sectionsForTopOfDialogs,
	sectionsForBottomOfDialog = ImmichUploadInfoDialogSections.sectionsForTopOfDialogs,
	
}