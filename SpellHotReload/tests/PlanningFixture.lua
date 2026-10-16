-- Test-only assembly of the CURRENT file-location path from genuine first-load captures.
-- No source execution, history reconstruction, publication or alternate comparison.
local M={}
function M.Report(capture,content,snapshot,base)
    local Driver=require("SpellHotReload.Pipeline.Driver")
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local Target=require("SpellHotReload.Adapters.Card.CardTarget")
    local Cards=require("SpellHotReload.Adapters.Card.CardVersions")
    base=base or capture.snapshot
    if not snapshot then
        local driver=Driver.New()
        assert(driver:RegisterDiscovery(Card))
        local found,err=driver:Discover(base.file,content,{session_id=base.session_id,
            registry_entry=base.entry,loaded_source=base.loaded_source,
            base_revision=base.revision,published_units=base,candidate_generation=1})
        if not found then return nil,err end
        snapshot=found.snapshot
    end
    local live={capture=capture,snapshot=base,entry=base.entry,
        session_id=base.session_id,classes=capture.classes,content=content or (type(snapshot)=="table" and getmetatable(snapshot)==nil and type(rawget(snapshot,"common"))=="table" and rawget(snapshot,"common").content)}
    local location,err=Target.LocateFileDiscovery(snapshot,capture,live)
    if not location then return nil,err end
    return Cards.CompareFileLocated(base,location,capture,live)
end
return M
