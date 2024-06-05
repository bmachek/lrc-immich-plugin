-- Lightroom SDK
local LrView = import 'LrView'
local LrTasks = import 'LrTasks'
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrColor = import 'LrColor'

require "ImmichAPI"

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

	propertyTable:addObserver( 'url', updateExportStatus )
	propertyTable:addObserver( 'apiKey', updateExportStatus )
	propertyTable:addObserver( 'album', updateExportStatus )
	propertyTable:addObserver( 'newAlbumName', updateExportStatus )
	propertyTable:addObserver( 'albums', updateExportStatus )
	propertyTable:addObserver( 'albumMode', updateExportStatus )
	propertyTable:addObserver( 'configOK', updateExportStatus )

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
						width_in_chars = 40,
						fill_horizontal = 1,
					},
				},

				f:column {

					f:push_button {
						title = 'Test connection',
						action = function () 
							if (ImmichAPI.checkConnectivity( propertyTable.url, propertyTable.apiKey ) == true) then
								LrDialogs.message('Connection successful. Config OK!')
								propertyTable.configOK = true
							else
								LrDialogs.showError('Connection not succesful, check URL and API key!')
								propertyTable.configOK = false
							end
						end
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

-------------------------------------------------------------------------------


function ImmichUploadExportDialogSections.sectionsForTopOfDialog( _, propertyTable )

	local f = LrView.osFactory()
	local bind = LrView.bind

	local checkConnectivityLabel = f:static_text {
		title = bind 'checkConnectivityLabelTitle',
		visible = bind 'checkConnectivityLabelVisible',
		text_color = bind 'checkConnectivityLabelColor',
		alignment = 'left',
	}

	local chooseAlbum = f:popup_menu {
		truncation = 'middle',
		width = 200,
		fill_horizontal = 1,
		value = bind 'album',
		items = bind 'albums',
		visible = LrBinding.keyEquals( "albumMode", "existing" ),
		align = left,
		immediate = true,
		enabled = bind 'configOK',
	}

	local newAlbumName = f:edit_field {
		truncation = 'middle',
		width = 200,
		fill_horizontal = 1,
		value = bind 'newAlbumName',
		visible = LrBinding.keyEquals( "albumMode", "new" ),
		align = left,
		immediate = true,
		enabled = bind 'configOK',
	}

	propertyTable.configOK = false
	propertyTable.checkConnectivityLabelVisible = true
	propertyTable.checkConnectivityLabelTitle = 'Checking Immich connectivity, please standy....'
	propertyTable.checkConnectivityLabelColor = LrColor( 0, 0, 0 )

	LrTasks.startAsyncTask( function ()
		propertyTable.configOK = ImmichAPI.checkConnectivity(propertyTable.url, propertyTable.apiKey)
		if  propertyTable.configOK then
			propertyTable.checkConnectivityLabelVisible = false
			propertyTable.albums = ImmichAPI.getAlbums( propertyTable.url, propertyTable.apiKey )
		else
			albums = {}
			propertyTable.checkConnectivityLabelTitle = 'Checking Immich connectivity FAILED!'
			propertyTable.checkConnectivityLabelColor = LrColor( 1, 0, 0 )
			LrDialogs.showError('Connection to Immich server failed, check URL and API key.')
		end
	end
)

	local result = {
	
		{
			title = "Immich Album Options",

			f:row {
				checkConnectivityLabel,
			},

			f:row {

				f:column {
					f:static_text {
						title = "Add to album during export:",
						alignment = 'right',
						visible = bind 'hasNoError',
					},
				},


				f:column {
					f:popup_menu {
						alignment = 'left',
						immediate = true,
						items = { 
							{ title = 'Existing album', value = 'existing'},
							{ title = 'Create new album', value = 'new'},
							{ title = 'Do not use an album', value = 'none'},
						},
						value = bind 'albumMode',
						enabled = bind 'configOK',
					},
				},

				f:column {

					place = "overlapping",

					chooseAlbum,
					newAlbumName,

				}, 

			},

		},
	}
	
	return result
	
end

