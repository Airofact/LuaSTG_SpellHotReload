-- Card domain/version core plus real two-owner FileCommit fixture. This is NOT
-- coverage of production Card's five hooks, Target/Current or FileApply remainder.
local M={}
local serial=0
function M.run()
    local Cards=require("SpellHotReload.Adapters.Card.CardVersions")
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local Callbacks=require("SpellHotReload.Adapters.Card.CardCallbacks")
    local Source=require("SpellHotReload.Source.FileAnalysis")
    local Local=require("SpellHotReload.Adapters.Local.Local")
    local LV=require("SpellHotReload.Adapters.Local.LocalVersions")
    local Definitions=require("SpellHotReload.Adapters.Local.LocalDefinitions")
    local Files=require("SpellHotReload.Pipeline.FileVersions")
    local Tx=require("SpellHotReload.Apply.FileCommit")
    local Load=require("SpellHotReload.Load.AnchorLoad")
    local Anchor=require("SpellHotReload.Load.Anchor")
    local Compose=require("SpellHotReload.Source.Compose")
    local Tree=require("SpellHotReload.Source.SyntaxTree")
    local IR=require("SpellHotReload.Source.TopLevelIR")
    local names={"before","init","frame","render","beforedel","del","after"}
    local defaults={};for _,name in ipairs(names) do defaults[name]=function() end end
    local saved={boss=rawget(_G,"boss"),_editor_class=rawget(_G,"_editor_class"),_tmp_sc=rawget(_G,"_tmp_sc")}
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
        "_editor_class['K'].cards={}",
        "_tmp_sc=boss.card.New('A',1,2,3,100)",
        "function _tmp_sc:init(n) return helper(n) end",
        "_tmp_sc.frame=function(self) return counter end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
    },"\n")
    -- Match is deliberately source/layout only, not a fake production Card hook.
    local function match(s)
        local result={units={}}
        for _,class in ipairs(must(Card.CardLists(s.analysis))) do
            result.units[#result.units+1]=Card.Unit(class.class_key,class.ranges,must(Callbacks.Read(s,class.class_key)))
        end
        return result
    end
    local function fixture()
        serial=serial+1
        _G.boss={card={New=function(name)
            local card={name=name,is_combat=true}
            for _,cb in ipairs(names) do card[cb]=defaults[cb] end
            return card
        end}}
        _G._editor_class={K={},Q={}}
        local entry=must(Load.Capture(source,{name="CardCore_Boss.lua"}));entry.file="CardCore_Boss.lua"
        local session="CardCoreSpec:"..serial
        local local_piece=must(Local.Capture(entry,session))
        local loaded=match(entry.source);local owners,ownership={},{}
        for _,unit in ipairs(loaded.units) do
            local key=unit.context.class_key;local class=_editor_class[key];local slots={}
            for slot,card in ipairs(class.cards) do
                slots[slot]=card
                local callbacks={};for _,cb in ipairs(names) do callbacks[cb]=rawget(card,cb) end
                owners[#owners+1]={class_key=key,slot=slot,card=card,callbacks=callbacks}
            end
            ownership[#ownership+1]={class_key=key,class=class,list=class.cards,slots=slots}
        end
        local card_piece=must(Cards.Seed(Card,entry,session,loaded,owners,ownership,_editor_class,defaults,function(binding)
            eq(Source.Declaration(entry.source,binding.name),binding,"first-load provider uses canonical Binding")
            return local_piece.state.by_name[binding.name].unit_ref
        end))
        local capture=must(Files.Capture(entry,session,{local_piece,card_piece}))
        return {entry=entry,session=session,capture=capture,classes=_editor_class,key="card:1:K:1"}
    end
    local function view(f,content,deleted)
        local s=must(Source.Build(content));local m=match(s);local desc=m.units[1].context.layout[1]
        local group,initial=Files.Owner(f.capture,Card);local rows={}
        if deleted then
            local previous
            for _,record in ipairs(group.records) do if record.key==f.key..":"..deleted then previous=record end end
            local row={status="deleted",previous=previous,candidate={descriptor=desc,slot=1,callback=deleted}}
            row.tombstone={owner=Card,owner_id=Card.Id,previous=previous,definition_version=previous.definition_version}
            rows[previous.key]=row
        end
        local locations={by_key={[f.key]={key=f.key,status="located",descriptor=desc,candidate_slot=1}}}
        return must(Cards.Compare(group,initial.evidence,s,m,locations,rows)),s
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
            local m=match(v.source);eq(#m.units,1,"layout consumes existing public syntax")
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
        local v,s=view(f,candidate);local projection=must(Definitions.Match(s))
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
            v,s=view(f,content);projection=must(Definitions.Match(s))
            local bad=dependencies(v,{{source=s,node=projection.definitions.helper[1].syntax,root_id="bad"}},{{root_id="bad"}})
            eq(#must(Cards.Constraints(v,bad)).blocked_roots,1,"full helper AST rejects pending/dynamic/missing generated binding")
        end
        v,s=view(f,(source:gsub("return counter%+n","return _editor_class['Q']")))
        projection=must(Definitions.Match(s));d=dependencies(v,{{source=s,node=projection.definitions.helper[1].syntax,root_id="safe"}},{{root_id="safe"}})
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
        local constructor=5
        eq(facts.excluded[constructor],true,"literal sixth three-number array is safe wiring")
        v,s=view(f,(content:gsub("{1,2,3}","{1,2,3+4}",1)));facts=must(Cards.Facts(s,v.match,{}))
        eq(facts.excluded[constructor],nil,"arithmetic sixth argument is not safe wiring")
        eq(Cards.Facts(s,{units={}},{}).excluded[6],nil,"unowned callback statement is never masked")
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
        local v,s=view(f,content);local lg,li=Files.Owner(f.capture,Local)
        local lv=must(LV.Compare(lg,li.evidence,must(Definitions.Match(s))))
        must(LV.Resolve(lv,"helper"));local lp=must(LV.Prepare(lv,{"counter","helper"}))
        local cp=must(Cards.Prepare(v,{},{}));local old_card=v.base_group
        local operation={capture=f.capture,base_snapshot=f.capture.snapshot,source=s,file=f.entry.file,
            entry=f.entry,anchor=f.entry.anchor,loaded_source=source,session_id=f.session,generation=1,mode="file"}
        local function fragment(owner,base,plan,next_group,guard)
            return {operation=operation,owner=owner,base_group=base,proposed_group=next_group,
                joins=plan.joins,cell_writes=plan.cell_writes,raw_writes=plan.raw_writes,
                read_set=plan.read_set,capture_reads=plan.capture_reads,owner_guard=guard}
        end
        local fragments={fragment(Local,lg,lp,must(LV.Next(lp)),function() return LV.Reads(lv)~=nil end),
            fragment(Card,old_card,cp,must(Cards.Next(cp)),function() return Cards.Guard(cp,f.classes) end)}
        local tx=must(Tx.New(f.session));local live={capture=f.capture,snapshot=f.capture.snapshot,
            entry=f.entry,session_id=f.session,content=content,generation=1}
        local ran,receipt,err=tx:Run(function(token) return tx:Commit(token,operation,fragments,live) end)
        must(tx:Release());eq(ran,true,"one real common transaction returned normally");must(receipt,err)
        eq(receipt.changed,true,"helper-only transaction has real changed receipt")
        eq(f.capture.snapshot.revision,1,"common file revision advances once")
        local card_group=must(Files.Owner(f.capture,Card))
        eq(card_group,old_card,"helper-only publication retains exact Card group")
        eq(card_group.state.units[f.key].definition_version,1,"Card source version stays v1")
        eq(card_group.state.units[f.key].callbacks.init.definition_version,1,"callback source version stays v1")
        local observations=must(Cards.Observations(f.capture.snapshot,card_group,f.key))
        eq(#observations,1,"ordinary evolving state is not a function observation")
        eq(observations[1].name,"helper","display names actual direct provider")
        eq(observations[1].version,2,"display derives helper v2 from common actual snapshot")
        eq(f.classes.K.cards[1]:init(2),15,"retained actual callback observes newly installed helper")
        eq(Cards.Observations(operation.base_snapshot,card_group,f.key)[1].version,1,"old snapshot display remains v1")
    end)
    _G.boss=saved.boss;_G._editor_class=saved._editor_class;_G._tmp_sc=saved._tmp_sc
    return {passed=passed,failed=failed,failures=failures}
end
return M
