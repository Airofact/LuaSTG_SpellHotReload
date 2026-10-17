-- Standalone offline subset; full offline validation executes each spec separately.
package.path = "plugin/SpellHotReload/?.lua;" .. package.path
for _,name in ipairs({"SandboxSpec","LexerSpec","TopLevelIRSpec","LoadCaptureSpec",
    "AdapterDiscoverySpec","ReconciliationSpec","CardReconciliationSpec","CardDeletionEvidenceSpec","DriverDiscoverySpec","WatcherSpec","CurrentRestartSpec"}) do
    local result=require("SpellHotReload.tests."..name).run()
    assert(result.failed==0,name.." failed")
end
