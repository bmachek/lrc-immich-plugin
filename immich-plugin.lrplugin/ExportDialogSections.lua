require "ImmichAPI"
require "StackManager"
require "SharedDialogSections"

ExportDialogSections = {}

local function _updateCantExportBecause(propertyTable)
	LrTasks.startAsyncTask(function()
		propertyTable.immich:reconfigure(propertyTable.url, propertyTable.apiKey)
		if not propertyTable.immich:checkConnectivity() then
			propertyTable.LR_cantExportBecause = "Immich connection not setup"
			return
		else
			propertyTable.albums = propertyTable.immich:getAlbums()
		end

		propertyTable.LR_cantExportBecause = nil
	end)
end

function ExportDialogSections.startDialog(propertyTable)
	LrTasks.startAsyncTask(function()
		propertyTable.immich = ImmichAPI:new(propertyTable.url, propertyTable.apiKey)
		propertyTable.albums = propertyTable.immich:getAlbums()
	end)
	
	SharedDialogSections.setupOriginalFileObservers(propertyTable)
end

-------------------------------------------------------------------------------

function ExportDialogSections.sectionsForBottomOfDialog(f, propertyTable)
	local bind = LrView.bind
	local share = LrView.share

	local result = {

		SharedDialogSections.getOriginalFilesSection(f, propertyTable),
		SharedDialogSections.getServerConnectionSection(f, propertyTable),
	}

	return result
end

-------------------------------------------------------------------------------

function ExportDialogSections.sectionsForTopOfDialog(_, propertyTable)
	local f = LrView.osFactory()
	local bind = LrView.bind

	local result = {

		{
			title = "Immich Album Options",
			f:column {
				f:row {
					f:column {
						f:row {
							f:static_text {
								title = "Add to album during export:",
								alignment = 'right',
							},
							f:popup_menu {
								alignment = 'left',
								immediate = true,
								items = {
									{ title = 'Choose on export',    value = 'onexport' },
									{ title = 'Existing album',      value = 'existing' },
									{ title = 'Create new album',    value = 'new' },
									{ title = 'Create/use folder name as album',    value = 'folder' },
									{ title = 'Do not use an album', value = 'none' },
								},
								value = bind 'albumMode',
							},
						},
					},

					f:column {
						place = "overlapping",
						f:popup_menu {
							truncation = 'middle',
							width_in_chars = 20,
							fill_horizontal = 1,
							value = bind 'album',
							items = bind 'albums',
							visible = LrBinding.keyEquals("albumMode", "existing"),
							align = "left",
						},
						f:edit_field {
							truncation = 'middle',
							width_in_chars = 20,
							fill_horizontal = 1,
							value = bind 'newAlbumName',
							align = "left",
							visible = LrBinding.keyEquals("albumMode", "new"),
						},
					},
				},
			},
		},
	}

	return result
end
