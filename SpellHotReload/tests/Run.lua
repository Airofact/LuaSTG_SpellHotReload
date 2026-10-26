-- LuaJIT offline subset; full validation runs each spec in a separate process.
package.path = "plugin/SpellHotReload/?.lua;" .. package.path
assert(type(jit)=="table" and type(debug.upvaluejoin)=="function",
    "Run.lua requires LuaJIT with genuine shared upvalue cells")
for _,name in ipairs({
    "SandboxSpec","LexerSpec","TopLevelIRSpec","LoadCaptureSpec",
    "AdapterDiscoverySpec","ReconciliationSpec","CardReconciliationSpec",
    "CardDeletionEvidenceSpec","DriverDiscoverySpec","WatcherSpec","CurrentRestartSpec",
    "DependenciesSpec","LocalVersionsSpec","LocalAdapterSpec","CardVersionCoreSpec",
    "CardAdapterSpec","FileCommitSpec","FilePolicyIntegrationSpec","PluginEntrySpec",
    "RetiredInterfacesSpec","NativeOwnershipSpec","IncrementalSourceSpec",
}) do
    local result=require("SpellHotReload.tests."..name).run()
    assert(result.failed==0,name.." failed")
end
