-- Test-only assembly of the REAL common pipeline. No legacy report or ledger.
-- The caller supplies a genuine entry immediately after its single first load,
-- the captured classes/defaults, complete FileAnalysis inputs and fresh live reads.
-- Prepare, Publish and Remaining are separate; this helper never auto-publishes.
local Local=require("SpellHotReload.Adapters.Local.Local")
local Card=require("SpellHotReload.Adapters.Card.Card")
local Files=require("SpellHotReload.Pipeline.FileVersions")
local Driver=require("SpellHotReload.Pipeline.Driver")
local Source=require("SpellHotReload.Source.FileAnalysis")
local FileApply=require("SpellHotReload.Apply.FileApply")
local M={}
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function fail(message)
    return nil,{phase="fixture",code="ownership",message=message}
end
-- No late reconstruction from current callbacks or a proposed snapshot.
function M.Capture(entry,session,classes,defaults)
    local local_piece,err=Local.Capture(entry,session)
    if not local_piece then return nil,err end
    local card_piece,why=Card.Capture(entry,session,local_piece,classes,defaults)
    if not card_piece then return nil,why end
    local capture,problem=Files.Capture(entry,session,{local_piece,card_piece})
    if not capture then return nil,problem end
    local driver=Driver.New()
    assert(driver:RegisterDiscovery(Local));assert(driver:RegisterDiscovery(Card))
    return {capture=capture,driver=driver,entry=entry,session=session}
end
-- The test input boundary builds once; later operations can reuse the exact facts
-- while still performing NEW discovery against the current actual publication.
function M.Discover(f,source,generation)
    if not plain(f) or not Files.Validate(f.capture) or not Source.Validate(source) then
        return fail("fixture and complete shared source required")
    end
    local publication,err=Files.Publication(f.capture)
    if not publication then return nil,err end
    return f.driver:DiscoverPublished(f.entry.file,source,publication,
        {capture=f.capture,generation=generation})
end
function M.Operation(f,discovery,options)
    if not plain(options) or type(options.refresh)~="function" or not plain(discovery)
        or discovery.owner~=f.driver or not plain(discovery.reconciliation)
        or discovery.snapshot.common.capture~=f.capture then
        return fail("original discovery and explicit fresh read required")
    end
    local mode=options.mode or "file"
    if mode~="file" and mode~="current" and mode~="inspect" then return fail("explicit operation mode required") end
    local roots,available,card_view={},{},nil
    for _,group in ipairs(discovery.reconciliation.groups) do
        if group.reason then return fail("complete original owner reconciliation required") end
        local list
        if group.owner==Local then list=Local.Roots(group.view)
        elseif group.owner==Card then list=Card.Roots(group.view);card_view=group.view
        else return fail("fixture supports its real Local/Card owners only") end
        for _,root in ipairs(list) do available[root.root_id]=root;roots[#roots+1]=root end
    end
    local card={refresh=options.refresh}
    if mode=="current" or mode=="inspect" then
        if options.root_ids~=nil then return fail("Current uses only Card's frozen private root") end
        local live,err=options.refresh();if not live then return nil,err end
        if not plain(live.binding) then return fail("Current binding required") end
        local root,target=Card.CurrentRoot(card_view,Card.FreezeBinding(live.binding),f.capture,live)
        if not root then return nil,target end
        roots={root};card.target=target
    elseif options.root_ids~=nil then
        -- root_ids are owner-private test requests, never discovery keys or graph nodes.
        local selected,seen={},{}
        if not plain(options.root_ids) then return fail("dense explicit root ids required") end
        local count=0;for key in next,options.root_ids do
            if type(key)~="number" or key<1 or key>=math.huge or key~=math.floor(key) then return fail("dense explicit root ids required") end
            count=count+1
        end
        for i=1,count do
            local id=options.root_ids[i]
            if type(id)~="string" or not available[id] or seen[id] then return fail("original unique root id required") end
            seen[id]=true;selected[#selected+1]=available[id]
        end
        roots=selected
    end
    local base=f.capture.snapshot
    return {capture=f.capture,base_snapshot=base,source=discovery.source,file=base.file,
        entry=base.entry,anchor=base.anchor,loaded_source=base.loaded_source,session_id=base.session_id,
        generation=discovery.snapshot.common.generation,mode=mode,roots=roots,card=card}
end
function M.Prepare(f,discovery,options)
    local operation,err=M.Operation(f,discovery,options)
    if not operation then return nil,err end
    local prepared,report=FileApply.Prepare(f.driver,discovery,operation)
    if not prepared then return nil,report end
    return prepared,report,operation
end
-- Caller owns controller creation/release. Only this explicit call may publish,
-- through both real registration hooks and ONE FileCommit transaction.
function M.Publish(f,prepared,controller)
    local op=prepared.operation;local refresh=op.card.refresh
    local live,err=refresh();if not live then return nil,err end
    local valid,why=FileApply.CheckProof(op,live);if not valid then return nil,why end
    local ran,receipt,problem=controller:Run(function(token)
        return f.driver:CommitDiscovery(prepared,function(operation,fragments)
            return controller:Commit(token,operation,fragments,live,FileApply.Refresh(operation,refresh))
        end)
    end)
    if not ran then return nil,receipt end
    return receipt,problem
end
function M.Remaining(f,source,generation,refresh)
    local discovery,err=M.Discover(f,source,generation)
    if not discovery then return nil,err end
    local operation,why=M.Operation(f,discovery,{mode="file",root_ids={},refresh=refresh})
    if not operation then return nil,why end
    return FileApply.InspectFileRemainder(f.driver,discovery,operation,refresh)
end
return M
