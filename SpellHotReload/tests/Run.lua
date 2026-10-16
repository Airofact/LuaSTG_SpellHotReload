-- Standalone smoke entry; full offline validation also executes each spec separately.
package.path = "plugin/SpellHotReload/?.lua;" .. package.path
for _,name in ipairs({"SandboxSpec","LexerSpec","TopLevelIRSpec","LoadCaptureSpec",
    "AdapterDiscoverySpec","DriverDiscoverySpec","WatcherSpec","CurrentRestartSpec"}) do
    local result=require("SpellHotReload.tests."..name).run()
    assert(result.failed==0,name.." failed")
end
