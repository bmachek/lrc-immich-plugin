-- Lightroom SDK
local LrView = import 'LrView'

ImmichUploadExportDialogSections = {}

local function updateExportStatus( propertyTable )
	
	local message = nil

	if message then
		propertyTable.message = message
		propertyTable.hasError = true
		propertyTable.hasNoError = false
		propertyTable.LR_cantExportBecause = message
	else
		propertyTable.message = nil
		propertyTable.hasError = false
		propertyTable.hasNoError = true
		propertyTable.LR_cantExportBecause = nil
	end
	
end

-------------------------------------------------------------------------------

function ImmichUploadExportDialogSections.startDialog( propertyTable )
	
	propertyTable:addObserver( 'items', updateExportStatus )
	propertyTable:addObserver( 'url', updateExportStatus )
	propertyTable:addObserver( 'apiKey', updateExportStatus )

	updateExportStatus( propertyTable )
	
end

-------------------------------------------------------------------------------

function ImmichUploadExportDialogSections.sectionsForBottomOfDialog( _, propertyTable )

	local f = LrView.osFactory()
	local bind = LrView.bind
	local share = LrView.share

	local result = {
	
		{
			title = LOC "$$$/ImmichUpload/ExportDialog/ImmichSettings=Immich Server URL",
			
			synopsis = bind { key = 'url', object = propertyTable },
			
			f:row {

				f:column {
					f:static_text {
						title = LOC "$$$/ImmichUpload/ExportDialog/URL=URL:",
						alignment = 'right',
						width = share 'labelWidth'
					},
				},

				f:column {

					f:edit_field {
						value = bind 'url',
						truncation = 'middle',
						immediate = true,
						fill_horizontal = 1,
					},
				},
			},
			
			f:row {
				
				f:column {
					f:static_text {
						title = LOC "$$$/ImmichUpload/ExportDialog/apiKey=API Key:",
						alignment = 'right',
						width = share 'labelWidth',
						visible = bind 'hasNoError',
					},
				},

				f:column {

					f:edit_field {
						value = bind 'apiKey',
						truncation = 'middle',
						immediate = true,
						fill_horizontal = 1,
					},
				},
			},
		},
	}
	
	return result
	
end
