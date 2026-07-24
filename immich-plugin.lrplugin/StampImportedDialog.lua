require("AssetStampTask")

-- Manually reconcile pending import stamps: match imported files to catalog photos by path
-- and write their Immich asset IDs. Purely local (no server call needed).
return {
    LrTasks.startAsyncTask(function()
        AssetStampTask.reconcile(true)
    end),
}
