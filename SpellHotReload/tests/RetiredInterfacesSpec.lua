local M={}
function M.run()
    local passed=0
    local function absent(module,names)
        local value=require("SpellHotReload."..module)
        for _,name in ipairs(names) do
            assert(value[name]==nil,module.." still exports "..name);passed=passed+1
        end
    end
    absent("Adapters.Card.Card",{"Request","Node","Signature","Bind","Plan","Restart","RestartVersioned","FreezeRestart",
        "PrepareVersioned","PrepareFileVersioned","InspectPrepared","CaptureVersions","SeedVersions",
        "CheckCommitInput","ProposeVersion","CheckOwnership","CheckCallbackRead","CheckPublications",
        "CheckJoinDestinations","RuntimeContext"})
    absent("Adapters.Card.CardCallbacks",{"Select","Build","Publish"})
    absent("Adapters.Card.PracticeBinding",{"Patch","Restart","FlyOut"})
    absent("Adapters.Card.CardVersions",{"CompareDiscovery","Publication"})
    assert(type(require("SpellHotReload.Adapters.Card.CardVersions").Compare)=="function",
        "Card private actual-version comparison missing");passed=passed+1
    absent("Source.FunctionPlan",{"Inspect","InspectDiscovery","PrepareDiscovery","DiscoveryPreparer"})
    absent("Pipeline.Driver",{"Register","Signature","Plan","Commit","Apply","Restart","Count","Select"})
    absent("Pipeline.Adapter",{"Validate","Fallback"})
    local registry=require("SpellHotReload.Pipeline.NodeRegistry").New()
    for _,name in ipairs({"Register","For","Carriers","_by_carrier","_fallback"}) do
        assert(registry[name]==nil,"carrier registry remains");passed=passed+1
    end
    local watcher_key="SpellHotReload.Runtime.Watcher"
    local saved_watcher=package.loaded[watcher_key]
    package.loaded[watcher_key]=saved_watcher or {}
    absent("Runtime.Plugin",{"GetRegistry","CaptureAnchor","_LoadedValues","_Publish","_ApplyLegacy"})
    local instance=require("SpellHotReload.Runtime.Plugin").New()
    assert(instance._registry==nil,"second map registry remains")
    assert(instance:_CheckLoad("Unloaded_Boss.lua")==false,"absent first load accepted")
    assert(instance:Release(),"cold instance release")
    package.loaded[watcher_key]=saved_watcher
    local anchors=require("SpellHotReload.Load.AnchorRegistry").New()
    for _,name in ipairs({"Get","Write","SetAll","Pending","Legacy","SetSource","_pending"}) do
        assert(anchors[name]==nil,"anchor publication facade remains");passed=passed+1
    end
    return {passed=passed,failed=0}
end
return M
