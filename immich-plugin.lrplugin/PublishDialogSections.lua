require("ImmichAPI")
require("SharedDialogSections")

PublishDialogSections = {}

function PublishDialogSections.startDialog(propertyTable)
    LrTasks.startAsyncTask(function()
        propertyTable.immich = ImmichAPI:new(propertyTable.url, propertyTable.apiKey)
    end)
    SharedDialogSections.setupOriginalFileObservers(propertyTable)
end

function PublishDialogSections.sectionsForTopOfDialog(f, propertyTable)
    local result = {
        SharedDialogSections.getOriginalFilesSection(f, propertyTable),
        SharedDialogSections.getLockedFolderSection(f, propertyTable),
        SharedDialogSections.getServerConnectionSection(f, propertyTable),
    }

    return result
end
