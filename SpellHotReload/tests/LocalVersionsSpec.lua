-- Actual Local versions, demand-only probes, selected preparation and one-owner
-- use of the common kernel. Production Card integration is tested separately.
local M={}
function M.run()
    local Source=require("SpellHotReload.Source.FileAnalysis")
    local Definitions=require("SpellHotReload.Adapters.Local.LocalDefinitions")
    local Local=require("SpellHotReload.Adapters.Local.LocalVersions")
    local Load=require("SpellHotReload.Load.AnchorLoad")
    local Anchor=require("SpellHotReload.Load.Anchor")
    local Versions=require("SpellHotReload.Pipeline.FileVersions")
    local Tx=require("SpellHotReload.Apply.FileCommit")
    local Compose=require("SpellHotReload.Source.Compose")
    local IR=require("SpellHotReload.Source.TopLevelIR")
    local passed,failed,failures=0,0,{}
    local function test(v,label)
        if v then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end
    end
    local function eq(a,b,label) test(rawequal(a,b),label) end
    local function must(v,e) assert(v,type(e)=="table" and e.message or e);return v end
    local create,analyze=Compose.Create,IR.Analyze
    local source=table.concat({
        "local counter=3",
        "local flag=false",
        "local empty=nil",
        "local shared={}",
        "local function helper() counter=counter+1;return counter,flag,empty,shared end",
        "local alias=helper",
        "local function other() return helper() end",
        "local function unused() return 900 end",
    },"\n")
    local ok,problem=pcall(function()
        local owner={Id="local"}
        local entry=must(Load.Capture(source,{name="Only_Boss.lua"}));entry.file="Only_Boss.lua"
        local projection=must(Definitions.Match(entry.source))
        local contribution=must(Local.Seed(owner,entry,"LocalVersionsSpec",projection))
        local capture=must(Versions.Capture(entry,"LocalVersionsSpec",{contribution}))
        local initial=capture.initial_owners[1].evidence
        local before=entry.map.helper
        local original_table=entry.map.shared
        local function view(content)
            local facts=must(Source.Build(content))
            return must(Local.Compare(capture.snapshot.owners[1],initial,must(Definitions.Match(facts))))
        end
        local unchanged=view(source)
        local constructions=0
        Compose.Create=function(...) constructions=constructions+1;return create(...) end
        local result=must(Local.Resolve(unchanged,"other"))
        eq(result.dependencies[1],"helper","retained root uses actual published dependency")
        must(Local.Resolve(unchanged,"helper"))
        eq(constructions,0,"unchanged definitions construct no candidate closures")
        local noop=must(Local.Prepare(unchanged,{"other","helper"}))
        eq(#noop.cell_writes,0,"unchanged selection writes nothing")
        eq(Local.Next(noop),capture.snapshot.owners[1],"unchanged selection keeps actual owner group")
        Compose.Create=create
        local candidate=source:gsub("counter%+1","counter+2"):gsub("return 900","return 901")
        local v=view(candidate)
        constructions=0
        Compose.Create=function(...) constructions=constructions+1;return create(...) end
        -- If prepare attempts full-file work after source/Match, fail immediately.
        IR.Analyze=function() error("repeated complete IR analysis") end
        must(Local.Resolve(v,"other"))
        eq(constructions,0,"helper-only change does not rebuild unchanged consumer")
        local helper=must(Local.Resolve(v,"helper"))
        eq(helper.changed,true,"actual helper definition differs")
        eq(constructions,1,"only demanded changed helper is constructed")
        must(Local.Resolve(v,"helper"))
        eq(constructions,1,"one operation reuses exact-node capture probe")
        test(v.by_name.unused.probe==nil,"unselected changed helper is not constructed")
        must(Anchor.Set(entry,"counter",41))
        local p=must(Local.Prepare(v,{"other","helper"}))
        eq(#p.cell_writes,1,"only changed selected definition has a cell write")
        eq(constructions,1,"prepare consumes probe without reconstructing closure")
        eq(Anchor.Get(entry,"counter"),41,"preparation does not replay initializer")
        eq(Anchor.Get(entry,"helper"),before,"preparation does not publish")
        IR.Analyze,Compose.Create=analyze,create
        local proposed=must(Local.Next(p))
        eq(proposed.state.by_name.helper.definition_version,2,"selected definition proposes next version")
        eq(proposed.state.by_name.unused.definition_version,1,"unselected definition version stays actual")
        local operation={capture=capture,base_snapshot=capture.snapshot,file=entry.file,
            entry=entry,anchor=entry.anchor,loaded_source=source,session_id="LocalVersionsSpec",
            generation=1,source=v.source,mode="file"}
        local fragment={operation=operation,owner=owner,base_group=capture.snapshot.owners[1],proposed_group=proposed,
            joins=p.joins,cell_writes=p.cell_writes,raw_writes=p.raw_writes,read_set=p.read_set,capture_reads=p.capture_reads,
            owner_guard=function() return Local.Reads(v)~=nil end}
        local tx=must(Tx.New("LocalVersionsSpec"))
        local live={capture=capture,snapshot=capture.snapshot,entry=entry,session_id="LocalVersionsSpec",
            content=candidate,generation=1}
        local ran,receipt,err=tx:Run(function(token) return tx:Commit(token,operation,{fragment},live) end)
        eq(ran,true,"common transaction scope")
        must(receipt,err)
        eq(capture.snapshot.revision,1,"one installed file revision")
        local current=must(Anchor.Get(entry,"other"))
        local value,flag,empty,shared=current()
        eq(value,43,"retained consumer sees selected helper and current scalar cell")
        eq(flag,false,"false state preserved");eq(empty,nil,"nil state preserved")
        eq(shared,original_table,"table identity preserved")
        eq(Anchor.Get(entry,"alias"),before,"alias keeps independent old closure value")
        eq((Anchor.Get(entry,"alias"))(),44,"old alias still uses old function over shared state")
        local after=view(candidate)
        eq(after.by_name.helper.changed,false,"new comparison uses actual installed helper version")
        eq(after.by_name.unused.changed,true,"pending definition still differs from actual version")
        eq(capture.snapshot.owners[1].state.by_name.other.definition_version,1,"shared impact does not advance consumer source")
        constructions=0
        Compose.Create=function(...) constructions=constructions+1;return create(...) end
        must(Local.Resolve(after,"other"));must(Local.Resolve(after,"helper"))
        eq(constructions,0,"post-publication retained definitions need no reconstruction")
        -- Actual identity is always checked, even when source/probe evidence exists.
        must(Anchor.Set(entry,"helper",function() end))
        eq(Local.Prepare(after,{"other","helper"}),nil,"external replacement refuses preparation")
        Compose.Create=create
        must(tx:Release())
    end)
    Compose.Create,IR.Analyze=create,analyze
    if not ok then failed=failed+1;failures[#failures+1]="spec threw: "..(type(problem)=="string" and problem or "opaque error") end
    return {passed=passed,failed=failed,failures=failures}
end
return M
