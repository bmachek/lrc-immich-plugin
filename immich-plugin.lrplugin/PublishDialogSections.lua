require "ImmichAPI"

PublishDialogSections = {}

local function _updateCantExportBecause(propertyTable)
	LrTasks.startAsyncTask(function()
		propertyTable.immich:reconfigure(propertyTable.url, propertyTable.apiKey)
		if not propertyTable.immich:checkConnectivity() then
			propertyTable.LR_cantExportBecause = "Immich connection not setup"
			return
		end
		propertyTable.LR_cantExportBecause = nil
	end)
end


function PublishDialogSections.startDialog(propertyTable)
	LrTasks.startAsyncTask(function()
		propertyTable.immich = ImmichAPI:new(propertyTable.url, propertyTable.apiKey)
		--_updateCantExportBecause(propertyTable)
	end)
	-- propertyTable:addObserver('url', _updateCantExportBecause)
	-- propertyTable:addObserver('apiKey', _updateCantExportBecause)
end

function PublishDialogSections.sectionsForTopOfDialog(f, propertyTable)
	local bind = LrView.bind
	local share = LrView.share

	local result = {

		{
			title = "Immich Server connection",
			bind_to_object = propertyTable,

			f:row {
				f:static_text {
					title = "URL:",
					alignment = 'right',
					width = share 'labelWidth'
				},
				f:edit_field {
					value = bind 'url',
					truncation = 'middle',
					immediate = false,
					fill_horizontal = 1,
					validate = function(_, url)
						return ImmichAPI.validateUrlForDialog(url, propertyTable.url, propertyTable.apiKey)
					end,
				},
				f:push_button {
					title = "Test connection",
					action = function()
						LrTasks.startAsyncTask(function()
							local success, message, api = ImmichAPI.testConnection(
								propertyTable.url, propertyTable.apiKey, propertyTable.immich)
							if api then
								propertyTable.immich = api
							end
							LrDialogs.message(message)
						end)
					end,
				},
			},

			f:row {
				f:static_text {
					title = "API Key:",
					alignment = "right",
					width = share "labelWidth",
				},
				f:password_field {
					value = bind "apiKey",
					truncation = "middle",
					immediate = false,
					fill_horizontal = 1,
				},
			},
		},
		{
			title = "Stacks",
			bind_to_object = propertyTable,
			f:column {
				f:row {
					f:static_text {
						title = "DNG+JPG:",
						alignment = 'right',
						width = LrView.share "label_width",
					},
					f:checkbox {
						title = "In Immich stapeln (bearbeitetes JPG als Primär)",
						value = bind 'stackDngJpg',
					},
				},
				f:row {
					f:static_text {
						title = "Lightroom-Stacks:",
						alignment = 'right',
						width = LrView.share "label_width",
					},
					f:checkbox {
						title = "Lightroom-Stacks in Immich übernehmen",
						value = bind 'stackLrStacks',
					},
				},
			},
		},
	}

	return result
end
