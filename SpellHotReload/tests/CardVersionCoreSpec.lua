-- Card domain/version core plus one real three-owner publication case.
-- This is not complete hook, Target/Current or FileApply remainder coverage.
local M={}
local serial=0
function M.run()
    local Cards=require("SpellHotReload.Adapters.Card.CardVersions")
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local Source=require("SpellHotReload.Source.FileAnalysis")
    local Local=require("SpellHotReload.Adapters.Local.Local")
    local ClassAdapter=require("SpellHotReload.Adapters.Class.Class")
    local ClassFixture=require("SpellHotReload.tests.ClassFixture")
    local Fixture=require("SpellHotReload.tests.PlanningFixture")
    local FileMatch=require("SpellHotReload.Pipeline.FileMatch")
    local Files=require("SpellHotReload.Pipeline.FileVersions")
    local Tx=require("SpellHotReload.Apply.FileCommit")
    local Load=require("SpellHotReload.Adapters.Class.ClassLoad")
    local Compose=require("SpellHotReload.Source.Compose")
    local IR=require("SpellHotReload.Source.TopLevelIR")
    local names={"before","init","frame","render","beforedel","del","after"}
    local defaults={};for _,name in ipairs(names) do defaults[name]=function() end end
    local environment
    local controllers={}
    local passed,failed,failures=0,0,{}
    local function eq(a,b,label) assert(rawequal(a,b),label);passed=passed+1 end
    local function must(v,e) assert(v,type(e)=="table" and e.message or e);return v end
    local function case(label,body)
        local ok,err=pcall(body)
        if not ok then failed=failed+1;failures[#failures+1]=label..": "..(type(err)=="string" and err or "opaque error") end
    end
    local source=table.concat({
        "local counter=3",
        "local function helper(n) return counter+n end",
        "local function unused() return 100 end",
        "_editor_class['K']=Class(boss)",
        "_editor_class['K'].cards={}",
        "_tmp_sc=boss.card.New('A',1,2,3,100)",
        "function _tmp_sc:init(n) return helper(n) end",
        "_tmp_sc.frame=function(self) return counter end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
    },"\n")
    -- Consume the completed shared discovery, never rebuild retired class units.
    local function match(f,s)
        local snapshot=must(f.driver:Discover(f.entry.file,s)).snapshot
        local card_context=must(FileMatch.ForOwner(snapshot,Card,s))
        local local_context=must(FileMatch.ForOwner(snapshot,Local,s))
        return card_context,local_context.projection
    end
    local function fixture()
        serial=serial+1
        if environment then environment:Restore() end
        environment=ClassFixture.Install()
        boss.card={_default_card=defaults,New=function(name)
            local card={name=name,is_combat=true}
            for _,cb in ipairs(names) do card[cb]=defaults[cb] end
            return card
        end}
        -- A real external Class, not an invented owner for this source.
        _editor_class.Q=Class(boss)
        local entry=must(Load.Capture(source,{name="CardCore_Boss.lua"}));entry.file="CardCore_Boss.lua"
        local session="CardCoreSpec:"..serial
        local f=must(Fixture.Capture(entry,session,_editor_class,defaults))
        environment:FinishLoad()
        f.classes=_editor_class;f.key="card:1:K:1"
        local lp=must(Files.GetAdapterRecords(f.capture,Local));local cp=must(Files.GetAdapterRecords(f.capture,Card))
        for _,name in ipairs(Source.DeclaredNames(entry.source)) do
            local binding=Source.Declaration(entry.source,name)
            local ref=lp.state.by_name[name].unit_ref
            eq(Local.CapturedProvider(lp,binding),ref,"first-load provider uses canonical declaration")
            eq(cp.state.providers[name],ref,"Card retains the canonical Local provider ref")
        end
        local parent=must(Files.GetAdapterRecords(f.capture,ClassAdapter))
        eq(cp.state.units[f.key].class_ref,parent.state.by_key.K.unit_ref,"Card retains its genuine Class provider")
        eq(parent.state.by_key.Q,nil,"external Class is not owned by this source")
        eq(#cp.units,1,"one actual card contributes one public unit")
        return f
    end
    local function view(f,content,deleted)
        local s=must(Source.Build(content));local m,projection=match(f,s)
        local desc=m.by_class.K.layout[1]
        local group,initial=Files.GetAdapterRecords(f.capture,Card);local rows={}
        if deleted then
            local previous
            for _,record in ipairs(group.records) do if record.key==f.key..":"..deleted then previous=record end end
            local row={status="deleted",previous=previous,candidate={descriptor=desc,slot=1,callback=deleted}}
            row.tombstone={owner=Card,owner_id=Card.Id,previous=previous,definition_version=previous.definition_version}
            rows[previous.key]=row
        end
        local locations={by_key={[f.key]={key=f.key,status="located",descriptor=desc,candidate_slot=1}}}
        return must(Cards.Compare(group,initial.evidence,s,m,locations,rows)),s,projection
    end
    local function no_scan(body)
        local create,analyze=Compose.Create,IR.Analyze
        local count=0
        Compose.Create=function(...) count=count+1;return create(...) end
        IR.Analyze=function() error("Card preparation repeated full-file parsing") end
        local ok,err=pcall(body,function() return count end)
        Compose.Create,IR.Analyze=create,analyze
        if not ok then error(err,0) end
    end
    local function dependencies(v,facts,roots)
        local op={source=v.source}
        return {stable=true,operation=op,source_facts=facts,safe_roots=roots}
    end
    case("source reuse and callback-only preparation",function()
        local f=fixture();local v=view(f,source)
        no_scan(function(count)
            local m=match(f,v.source);eq(#m.units,1,"layout consumes existing public syntax")
            local r=must(Cards.Resolve(v,f.key))
            eq(r.changed,false,"unchanged callbacks use actual records")
            eq(count(),0,"unchanged callback selection creates no closures")
            local p=must(Cards.Prepare(v,{f.key},{}))
            eq(Cards.Next(p),v.base_group,"no Card write retains exact group")
            eq(#p.raw_writes,0,"unchanged callbacks have no raw writes")
        end)
        local candidate=source:gsub("return helper%(n%)","return helper(n)+1"):gsub("return 100","return 101")
        v=view(f,candidate)
        no_scan(function(count)
            local resolved=must(Cards.Resolve(v,f.key))
            eq(count(),1,"only changed selected callback is constructed")
            eq(resolved.providers[1],f.capture.snapshot.owners[1].state.by_name.helper.unit_ref,"Card routes original provider ref")
            must(Cards.Resolve(v,f.key));eq(count(),1,"same operation reuses exact callback probe")
            local d=dependencies(v,{{source=v.source,node=resolved.callbacks.init.syntax,root_id="card"}},{{root_id="card"}})
            local c=must(Cards.Constraints(v,d));eq(#c.blocked_roots,0,"safe callback fact accepted")
            local p=must(Cards.Prepare(v,{f.key},must(Cards.RetainConstraints(v,c,d))))
            eq(count(),1,"final preparation does not recompile callback or unrelated Local")
            eq(#p.raw_writes,1,"only selected init raw slot proposed")
            eq(p.raw_writes[1].key,"init","raw target is actual callback slot")
            eq(rawget(v.base.units[f.key].card,"init"),v.base.units[f.key].callbacks.init.fn,"preparation never publishes callback")
            local next_group=must(Cards.Next(p))
            eq(next_group.state.units[f.key].definition_version,2,"changed callback proposes Card v2")
            eq(next_group.state.units[f.key].callbacks.frame.definition_version,1,"retained callback keeps actual v1")
            eq(next_group.state.functions,nil,"Card has no nested Local ledger")
        end)
    end)
    case("selected Local AST constraints and root pruning",function()
        local f=fixture()
        local candidate=source:gsub("return counter%+n","return _editor_class['K']"):gsub("'A',1,2","'A',2,2")
        local v,s,projection=view(f,candidate)
        local node=projection.definitions.helper[1].syntax
        local independent=projection.definitions.unused[1].syntax
        local d=dependencies(v,{{source=s,node=node,root_id="bad"},{source=s,node=independent,root_id="good"}},
            {{root_id="bad"},{root_id="good"}})
        local c=must(Cards.Constraints(v,d))
        eq(#c.blocked_roots,1,"pending class blocks only root with changed helper reference")
        eq(c.blocked_roots[1].root_id,"bad","block retains original root id")
        local pruned={stable=true,operation=d.operation,source_facts={d.source_facts[2]},safe_roots={{root_id="good"}}}
        eq(#must(Cards.RetainConstraints(v,c,pruned)),0,"blocked root contributes no registry read")
        for _,body in ipairs({"_tmp_sc","_sc_table","_editor_class[n]","_editor_class['missing']",
            "function() return _tmp_sc end"}) do
            local content=source:gsub("return counter%+n","return "..body):gsub("'A',1,2","'A',2,2")
            v,s,projection=view(f,content)
            local bad=dependencies(v,{{source=s,node=projection.definitions.helper[1].syntax,root_id="bad"}},{{root_id="bad"}})
            eq(#must(Cards.Constraints(v,bad)).blocked_roots,1,"full helper AST rejects pending/dynamic/missing generated binding")
        end
        v,s,projection=view(f,(source:gsub("return counter%+n","return _editor_class['Q']")))
        d=dependencies(v,{{source=s,node=projection.definitions.helper[1].syntax,root_id="safe"}},{{root_id="safe"}})
        c=must(Cards.Constraints(v,d));local reads=must(Cards.RetainConstraints(v,c,d))
        eq(#reads,1,"safe helper produces one Card-owned registry proof")
        local p=must(Cards.Prepare(v,{},reads));eq(Cards.Guard(p,f.classes),true,"no-write Card still guards helper registry")
        local old=f.classes.Q;f.classes.Q={}
        local accepted,err=Cards.Guard(p,f.classes)
        eq(accepted,nil,"external registry replacement refuses no-write Card guard")
        eq(err.code,"stale","registry drift is stale");f.classes.Q=old
        local removed={stable=true,operation=d.operation,source_facts={},safe_roots={{root_id="safe"}}}
        eq(Cards.RetainConstraints(v,c,removed),nil,"surviving root cannot silently lose source proof")
    end)
    case("narrow wiring and top-level read facts",function()
        local f=fixture();local v,s=view(f,source.."\nlocal alias=_tmp_sc")
        local facts=must(Cards.Facts(s,v.match,{}));local last=#s.analysis.statements
        eq(facts.binding_reads[last],true,"top-level alias read is not hidden by class window")
        eq(facts.excluded[last],nil,"Local declaration coverage stays with Local")
        for _,expression in ipairs({
            "(function() return _tmp_sc end)()",
            "(function() return _sc_table end)()",
            "(function() return _editor_class['K'] end)()",
            "(function() return function() return _tmp_sc end end)()()",
            "invoke(function() return _tmp_sc end)",
        }) do
            v,s=view(f,source.."\nlocal cached="..expression)
            facts=must(Cards.Facts(s,v.match,{K=true}))
            eq(facts.binding_reads[#s.analysis.statements],true,"evaluated call conservatively includes immediately callable function body")
        end
        v,s=view(f,source.."\nlocal delayed=function() return _tmp_sc end")
        facts=must(Cards.Facts(s,v.match,{K=true}))
        eq(facts.binding_reads[#s.analysis.statements],nil,"ordinary delayed function body is not a top-level read")
        local content=source:gsub("'A',1,2,3,100","'A',1,2,3,100,{1,2,3}")
        v,s=view(f,content);facts=must(Cards.Facts(s,v.match,{}))
        local constructor=v.match.by_class.K.layout[1].first
        eq(facts.excluded[constructor],true,"literal sixth three-number array is safe wiring")
        v,s=view(f,(content:gsub("{1,2,3}","{1,2,3+4}",1)));facts=must(Cards.Facts(s,v.match,{}))
        eq(facts.excluded[constructor],nil,"arithmetic sixth argument is not safe wiring")
        local callback=must(Source.Site(s,v.match.by_class.K.layout[1].callback_syntax.init)).statement
        eq(Cards.Facts(s,{units={}},{}).excluded[callback],nil,"unowned callback statement is never masked")
    end)
    case("optional deletion and complete actual callback read set",function()
        local f=fixture();local content=source:gsub("_tmp_sc.frame=function%(self%) return counter end\n","")
        local v=view(f,content)
        eq(Cards.Resolve(v,f.key),nil,"absence without exact tombstone is not executable")
        v=view(f,content,"frame");local r=must(Cards.Resolve(v,f.key))
        eq(r.requires_file_check,true,"optional deletion still requires complete FileApply proof")
        local p=must(Cards.Prepare(v,{f.key},{}))
        eq(p.raw_writes[1].value,defaults.frame,"deletion proposes exact saved default")
        eq(#p.read_set,7,"all seven actual callbacks are read")
        local old=f.classes.K.cards[1].after;f.classes.K.cards[1].after=function() end
        local accepted,err=Cards.Guard(p,f.classes)
        eq(accepted,nil,"unselected callback external replacement is rejected")
        eq(err.code,"stale","callback replacement is stale");f.classes.K.cards[1].after=old
    end)
    case("helper-only real common transaction and derived observation",function()
        local f=fixture();local content=source:gsub("counter%+n","counter+n+10")
        local s=must(Source.Build(content));local base=f.capture.snapshot
        local old_card=must(Files.GetAdapterRecords(f.capture,Card));local old_class=must(Files.GetAdapterRecords(f.capture,ClassAdapter))
        local function live() return {capture=f.capture,snapshot=f.capture.snapshot,entry=f.entry,
            classes=f.classes,session_id=f.session,content=content,generation=1} end
        local discovery=must(Fixture.Discover(f,s,1))
        local prepared=must(Fixture.Prepare(f,discovery,{mode="file",root_ids={f.key},refresh=live}))
        eq(#prepared.entries,3,"complete actual Local/Class/Card preparation")
        eq(prepared.entries[2].owner,ClassAdapter,"Class has its real common fragment")
        eq(#prepared.entries[2].fragment.raw_writes,0,"unchanged Class grants no new raw write")
        local tx=must(Tx.New(f.session));controllers[#controllers+1]=tx
        local receipt=must(Fixture.Publish(f,prepared,tx))
        eq(#receipt.owner_deltas,3,"one common transaction contains all three actual owners")
        for _,delta in ipairs(receipt.owner_deltas) do
            eq(delta.changed,delta.owner==Local,"only Local actually installs a definition")
        end
        eq(receipt.changed,true,"helper-only transaction has real changed receipt")
        eq(f.capture.snapshot.revision,1,"common file revision advances once")
        local card_group=must(Files.GetAdapterRecords(f.capture,Card))
        eq(card_group,old_card,"helper-only publication retains exact Card group")
        eq(Files.GetAdapterRecords(f.capture,ClassAdapter),old_class,"helper-only publication retains exact Class group")
        eq(card_group.state.units[f.key].definition_version,1,"Card source version stays v1")
        eq(card_group.state.units[f.key].callbacks.init.definition_version,1,"callback source version stays v1")
        local observations=must(Cards.Observations(f.capture.snapshot,card_group,f.key))
        eq(#observations,2,"only actual Class and helper definitions are observed")
        local observed={};for _,row in ipairs(observations) do observed[row.name]=row.version end
        eq(observed["class:K"],1,"display includes the actual owning Class v1")
        eq(observed.helper,2,"display derives helper v2 from common actual snapshot")
        eq(observed.counter,nil,"ordinary evolving state is not a definition observation")
        eq(observed["class:Q"],nil,"external Class has no invented ownership record")
        eq(f.classes.K.cards[1]:init(2),15,"retained actual callback observes newly installed helper")
        local previous={}
        for _,row in ipairs(must(Cards.Observations(base,card_group,f.key))) do previous[row.name]=row.version end
        eq(previous.helper,1,"old snapshot display remains helper v1")
        eq(previous["class:K"],1,"old snapshot retains genuine Class v1")
    end)
    for _,tx in ipairs(controllers) do eq(tx:Release(),true,"common controller released") end
    if environment then environment:Restore() end
    return {passed=passed,failed=failed,failures=failures}
end
return M
