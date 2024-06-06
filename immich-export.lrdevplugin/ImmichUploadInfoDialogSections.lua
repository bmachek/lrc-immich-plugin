-- Lightroom SDK
local LrView = import 'LrView'
local LrTasks = import 'LrTasks'
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrColor = import 'LrColor'
local prefs = import 'LrPrefs'.prefsForPlugin() 

require "ImmichAPI"

ImmichUploadInfoDialogSections = {}

-------------------------------------------------------------------------------

function ImmichUploadInfoDialogSections.sectionsForTopOfDialog( _, propertyTable )

    -- LrDialogs.message('PATSCH')

	local f = LrView.osFactory()
	local bind = LrView.bind
	local share = LrView.shares

	local result = {
		{
			title = "Immich server connection",
						
			f:row {

				f:column {
					f:static_text {
						title = "URL:",
						alignment = 'right',
						width = share 'labelWidth'
					},
				},

				f:column {
					f:edit_field {
						value = bind 'url',
						truncation = 'middle',
						immediate = true,
						width_in_chars = 40,
						fill_horizontal = 1,
					},
				},
			},
			
			f:row {				
				f:column {
					f:static_text {
						title = "API Key:", 
						alignment = 'right',
						width = share 'labelWidth',
						visible = bind 'hasNoError',
					},
				},

				f:column {
					f:password_field {
						value = bind 'apiKey',
						truncation = 'middle',
						immediate = true,
						width_in_chars = 40,
						fill_horizontal = 1,
					},
				},
			},
		},
	}
	
	return result
	
end


