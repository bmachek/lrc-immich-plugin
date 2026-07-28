require("ImmichAPI")
require("SharedDialogSections")

PublishDialogSections = {}

function PublishDialogSections.startDialog(propertyTable)
    LrTasks.startAsyncTask(function()
        propertyTable.immich = ImmichAPI:new(Util.resolveConnection(propertyTable))
    end)
    SharedDialogSections.setupOriginalFileObservers(propertyTable)
end

function PublishDialogSections.sectionsForTopOfDialog(f, propertyTable)
    local result = {
        SharedDialogSections.getOriginalFilesSection(f, propertyTable),
        SharedDialogSections.getLockedFolderSection(f, propertyTable),
        SharedDialogSections.getServerConnectionSection(f, propertyTable, { allowGlobal = true }),
    }

    return result
end
