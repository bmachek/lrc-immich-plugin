PublishDialogSections = {}


local function updatePublishStatus(propertyTable)
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


function PublishDialogSections.startDialog(propertyTable)
	propertyTable:addObserver('url', updatePublishStatus)
	propertyTable:addObserver('apiKey', updatePublishStatus)

	updatePublishStatus(propertyTable)
end

function PublishDialogSections.sectionsForTopOfDialog(_, propertyTable)
	local f = LrView.osFactory()
	local bind = LrView.bind
	local share = LrView.share

	local result = {

		{
			title = "Immich Server URL",

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
					width_in_chars = 40,
					-- fill_horizontal = 1,
					-- validate = function (v, url)
					-- 	sanitizedURL = propertyTable.immich:sanityCheckAndFixURL()
					-- 	if sanitizedURL == url then
					-- 		return true, url, ''
					-- 	elseif not (sanitizedURL == nil) then
					-- 		LrDialogs.message('Entered URL was autocorrected to ' .. sanitizedURL)
					-- 		return true, sanitizedURL, ''
					-- 	end
					-- 	return false, url, 'Entered URL not valid.\nShould look like https://demo.immich:app'
					-- end,
					enabled = false, -- Move configuration to Module Manager / PluginInfo
				},
			},

			f:row {
				f:static_text {
					title = "API Key:",
					alignment = 'right',
					width = share 'labelWidth',
					visible = bind 'hasNoError',
				},
				f:password_field {
					value = bind 'apiKey',
					truncation = 'middle',
					immediate = true,
					width_in_chars = 40,
					-- fill_horizontal = 1,
					enabled = false, -- Move configuration to Module Manager / PluginInfo
				},
			},
		},
	}

	return result
end
