require "ImmichAPI"
require "SharedDialogSections"

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
	SharedDialogSections.setupOriginalFileObservers(propertyTable)
end

function PublishDialogSections.sectionsForTopOfDialog(f, propertyTable)
	local bind = LrView.bind
	local share = LrView.share

	local result = {
		SharedDialogSections.getOriginalFilesSection(f, propertyTable),
		SharedDialogSections.getServerConnectionSection(f, propertyTable),
	}

	return result
end
