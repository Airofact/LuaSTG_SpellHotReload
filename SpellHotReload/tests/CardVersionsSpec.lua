-- Actual Card definitions and Local observations share ONE file publication.
-- Only miniature explicit first-load fixtures execute; preparation never publishes.
local M={}
local serial=0
function M.run()
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local Versions=require("SpellHotReload.Adapters.Card.CardVersions")
    local Local=require("SpellHotReload.Adapters.Local.Local")
    local Files=require("SpellHotReload.Pipeline.FileVersions")
    local Load=require("SpellHotReload.Adapters.Class.ClassLoad")
    local ClassAdapter=require("SpellHotReload.Adapters.Class.Class")
    local ClassFixture=require("SpellHotReload.tests.ClassFixture")
    local FileMatch=require("SpellHotReload.Pipeline.FileMatch")
    local Source=require("SpellHotReload.Source.FileAnalysis")
    local Anchor=require("SpellHotReload.Load.Anchor")
    local Compose=require("SpellHotReload.Source.Compose")
    local Planning=require("SpellHotReload.tests.PlanningFixture")
    local Guard=require("SpellHotReload.Apply.CommitCheck")
    local Dependencies=require("SpellHotReload.Pipeline.Dependencies")
    local Tx=require("SpellHotReload.Apply.FileCommit")
    local names={"before","init","frame","render","beforedel","del","after"}
    local passed,failed,failures=0,0,{}
    local controllers={}
    local environment
    local function check(value,label)
        if value then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end
    end
    local function eq(a,b,label) check(rawequal(a,b),label) end
    local function list(a,expected,label) eq(table.concat(a,","),expected,label) end
    local function must(v,e) assert(v,type(e)=="table" and e.message or e);return v end
    local function refuse(fn,code,label)
        local v,e=fn();eq(v,nil,label.." refused");eq(type(e),"table",label.." structured")
        if type(e)=="table" then
            eq(e.code,code,label.." code");check(type(e.message)=="string" and e.message~="",label.." message")
        end
    end
    local function copy(v) local out={};for k,x in next,v do out[k]=x end;return out end
    local function group(snapshot,owner)
        for _,g in ipairs(snapshot.owners) do if g.owner==owner then return g end end
        error("missing actual owner")
    end
    local function cards(snapshot) return group(snapshot,Card).state end
    local function locals(snapshot) return group(snapshot,Local).state end
    local function fragment(p,owner)
        for _,r in ipairs(p.entries) do if r.owner==owner then return r.fragment end end
        error("missing real preparation")
    end
    local function cardplan(p) return fragment(p,Card).card_plan end
    local function localplan(p) return fragment(p,Local) end
    local function seal(p)
        local fragments={};for _,r in ipairs(p.entries) do fragments[#fragments+1]=r.fragment end
        return must(Guard.Seal(p.operation,fragments))
    end
    local function description(p)
        local sealed=seal(p)
        local impact=must(Dependencies.PublicationImpact(sealed.proposed_snapshot,sealed.owner_deltas))
        local context={operation=p.operation,snapshot=p.operation.base_snapshot,
            dependencies=p.dependencies,impact=impact}
        return must(Card.Describe(fragment(p,Card),context)),must(Local.Describe(fragment(p,Local),context)),sealed
    end
    local function fields(rows,field,strip)
        local out={};for _,r in ipairs(rows) do
            if r[field] then out[#out+1]=strip and r.key:sub(#strip+1) or r.key end
        end
        return out
    end
    local function changes(p)
        local out={};local v=cardplan(p).view
        for _,key in ipairs(v.base.order) do if v.by_key[key].changed then out[#out+1]=key end end
        return out
    end
    local function observed(snapshot,key)
        local out={};for _,r in ipairs(must(Versions.Observations(snapshot,group(snapshot,Card),key))) do
            out[r.name]=r.version
        end
        return out
    end
    local defaults={};for _,name in ipairs(names) do defaults[name]=function() return "default" end end
    local globals={"boss","_editor_class","_tmp_sc","jit"}
    local saved={};for _,name in ipairs(globals) do saved[name]=rawget(_G,name) end
    local saved_join,saved_set=debug.upvaluejoin,debug.setupvalue
    local function firstload(bytes)
        if environment then environment:Restore() end
        environment=ClassFixture.Install()
        boss.card={_default_card=defaults,New=function(label)
            local card={name=label,is_combat=true}
            for _,name in ipairs(names) do card[name]=defaults[name] end
            return card
        end}
        local entry=must(Load.Capture(bytes,{name="Cards_Boss.lua"}))
        must(entry.reloadable,entry.reason);entry.file="Cards_Boss.lua"
        return entry,_editor_class
    end
    local function adopt(entry,classes)
        serial=serial+1
        local f=must(Planning.Capture(entry,"CardVersionsSpec:"..serial,classes,defaults))
        environment:FinishLoad()
        f.classes,f.content,f.generation=classes,entry.loaded_source,0
        f.initial_match=must(FileMatch.ForOwner(f.initial_discovery.snapshot,Card,entry.source))
        f.initial_owners,f.ownership=Card.CaptureOwnership(f.initial_match,classes,entry)
        must(f.initial_owners,f.ownership)
        f.refresh=function() return {capture=f.capture,snapshot=f.capture.snapshot,entry=entry,
            classes=classes,session_id=f.session,content=f.content,generation=f.generation} end
        return f
    end
    local function fixture(bytes) local entry,classes=firstload(bytes);return adopt(entry,classes) end
    -- Input/read helpers only; no legacy Report/Select/Next compatibility shape.
    local function discover(f,bytes)
        f.content,f.generation=bytes,f.generation+1
        local facts,err=Source.Build(bytes);if not facts then return nil,err end
        return Planning.Discover(f,facts,f.generation)
    end
    local function prepare(f,bytes,ids,blocked)
        local d,err=discover(f,bytes);if not d then return nil,err end
        local p,report=Planning.Prepare(f,d,{mode="file",root_ids=ids,refresh=f.refresh})
        if not p then return nil,report end
        if not blocked then
            eq(#p.dependencies.safe_roots,#ids,"every requested root is genuinely safe")
            eq(#p.dependencies.blocked_roots,0,"no success masked by blocked roots")
        end
        return p,d
    end
    local function publish(f,p)
        if not f.tx then f.tx=must(Tx.New(f.session));controllers[#controllers+1]=f.tx end
        return Planning.Publish(f,p,f.tx)
    end
    -- Direct private first-load seam: genuine source/layout/providers, malformed
    -- owner input only. Never adopt the resulting group as a second publication.
    local function seed_owners(f,owners,defs,local_group)
        local_group=local_group or group(f.capture.snapshot,Local)
        local class_group=group(f.capture.snapshot,ClassAdapter)
        return Versions.Seed(Card,f.entry,f.session,f.initial_match,owners,f.ownership,f.classes,defs,
            function(binding) return Local.CapturedProvider(local_group,binding) end,
            function(key) return ClassAdapter.CapturedProvider(class_group,key) end)
    end
    local source=table.concat({
        "local counter=4","local flag=false","local empty",
        "local function helper(n) return counter+n end",
        "local function other(n) return n+100 end",
        "local function pattern(n) return helper(n) end",
        "local alias=helper",
        "_editor_class['K']=Class(boss)",
        "_editor_class['K'].cards={}",
        "_tmp_sc=boss.card.New('A',1,2,3,100)",
        "function _tmp_sc:init(n) return pattern(n) end",
        "_tmp_sc.frame=function(self,n) return alias(n) end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
        "_tmp_sc=boss.card.New('B',1,2,3,100)",
        "function _tmp_sc:init(n) return pattern(n)+10 end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
        "_tmp_sc=boss.card.New('C',1,2,3,100)",
        "function _tmp_sc:init(n) return other(n) end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
    },"\n")
    local keya,keyb,keyc="card:1:K:1","card:1:K:2","card:1:K:3"
    local ok,problem=pcall(function()
        must(Anchor.Supported(Compose.Capability(debug))) -- real LuaJIT capabilities
        local entry,classes=firstload(source)
        local identities={helper=Anchor.Get(entry,"helper"),other=Anchor.Get(entry,"other"),pattern=Anchor.Get(entry,"pattern")}
        local joins,writes,flushes=0,0,0
        debug.upvaluejoin=function() joins=joins+1;error("premature join") end
        debug.setupvalue=function() writes=writes+1;error("premature write") end
        _G.jit={flush=function() flushes=flushes+1;error("premature flush") end}
        local f=adopt(entry,classes)
        local base=f.capture.snapshot;local state=cards(base)
        local a,b,c=classes.K.cards[1],classes.K.cards[2],classes.K.cards[3]
        eq(Versions.Kind,"SpellHotReload.CardVersions","kind");eq(Versions.Version,2,"version")
        eq(base.revision,0,"sole file revision starts at zero")
        eq(state.functions,nil,"Card holds no Local ledger");eq(state.revision,nil,"Card holds no file revision")
        eq(state.loaded_source,source,"immutable baseline");eq(state.anchor,entry.anchor,"sole anchor")
        eq(state.session_id,f.session,"session identity")
        list(state.order,keya..","..keyb..","..keyc,"complete captured cards")
        eq(#base.owners,3,"one actual Local/Class/Card capture")
        local class_group=group(base,ClassAdapter);local class_ref=class_group.state.by_key.K.unit_ref
        local refs={}
        eq(#group(base,Card).units,3,"three cards are three public units")
        for _,key in ipairs(state.order) do
            local unit=state.units[key]
            eq(unit.card,classes.K.cards[unit.slot],"genuine raw target")
            eq(refs[unit.unit_ref],nil,"each actual card has a distinct unit ref");refs[unit.unit_ref]=true
            eq(unit.class_ref,class_ref,"each card keeps its exact Class provider")
            local edge=false
            for _,row in ipairs(base.graph) do
                if row.consumer==unit.unit_ref and row.provider==class_ref then edge=true end
            end
            eq(edge,true,"actual publication has the Card-to-Class edge")
        end
        eq(state.units[keya].definition_version,1,"initial definition version")
        list(state.units[keya].callbacks.init.dependencies,"pattern","actual init capture")
        list(state.units[keya].callbacks.frame.dependencies,"alias","alias capture terminates")
        eq(state.units[keya].callbacks.init.fn,a.init,"first callback identity")
        eq(state.units[keya].callbacks.after.fn,defaults.after,"saved default")
        eq(state.units[keya].observed,nil,"no duplicate observation ledger")
        local observation=observed(base,keya)
        eq(observation.helper,1,"transitive helper observation");eq(observation.pattern,1,"direct observation")
        eq(observation.other,nil,"independent not observed");eq(observation.alias,nil,"state alias not function")
        eq(observation["class:K"],1,"actual owning Class is observed")
        local same=must(prepare(f,source,{}));local sc,sl,ss=description(same)
        list(changes(same),"","unchanged callbacks");list(fields(sc.cards,"affected"),"","unchanged impact")
        list(localplan(same).local_view.version_view.changed,"","unchanged Local")
        eq(#localplan(same).cell_writes,0,"empty writes");eq(#cardplan(same).publications,0,"empty callbacks")
        eq(ss.proposed_snapshot,base,"empty roots retain actual snapshot")
        local current=must(prepare(f,source,{keya}))
        eq(#cardplan(current).publications,0,"unchanged callback not rebuilt")
        eq(seal(current).proposed_snapshot,base,"unchanged selected root no revision")
        local selected_names=localplan(current).local_names
        list(selected_names,"counter,helper,pattern,alias","actual capture providers; alias retained as state")
        eq(#cardplan(current).read_set,21,"all seven raw callbacks on every card rechecked")
        check(#cardplan(current).capture_reads>=4,"physical capture reads retained")
        local formatted=must(prepare(f,source:gsub("return pattern%(n%) end","return -- comment\n pattern ( n ) end",1),{keya}))
        list(changes(formatted),keya,"in-span callback formatting is a content change")
        local all=source:gsub("counter%+n","counter+n+1")
            :gsub("pattern%(n%) end","pattern(n)+20 end",1):gsub("pattern%(n%)%+10","pattern(n)+30"):gsub("n%+100","n+200")
        local selected=must(prepare(f,all,{keya}));local dc,dl,sealed=description(selected)
        list(changes(selected),keya..","..keyb,"two wrappers edited")
        list(localplan(selected).local_view.version_view.changed,"helper,other","two Local definitions edited")
        list(cardplan(selected).keys,keya,"only requested card selected")
        list(fields(dc.cards,"pending"),keyb,"other wrapper pending")
        list(localplan(selected).local_names,"counter,helper,pattern,alias","exact actual dependency union")
        eq(#localplan(selected).cell_writes,1,"only needed helper installed")
        eq(localplan(selected).cell_writes[1].name,"helper","helper write exact")
        list(fields(dl.functions,"pending","local:"),"other","independent Local pending")
        list(fields(dc.cards,"affected"),keya..","..keyb,"impact excludes unrelated pending Local")
        local publications=cardplan(selected).publications
        eq(#publications,1,"only selected init publication");eq(publications[1].target,a,"exact table")
        eq(publications[1].key,"init","exact callback");eq(publications[1].before,a.init,"old identity")
        eq(selected.operation.source.content,all,"complete candidate retained");eq(cardplan(selected).restarts,nil,"no restart data")
        local proposed=sealed.proposed_snapshot;local pc=cards(proposed)
        eq(proposed.revision,1,"one proposed common revision")
        eq(locals(proposed).by_name.helper.definition_version,2,"only selected Local version advances")
        eq(locals(proposed).by_name.other.definition_version,1,"independent Local stays old")
        eq(pc.units[keya].definition_version,2,"selected wrapper advances")
        eq(pc.units[keya].callbacks.init.definition_version,2,"init advances")
        eq(pc.units[keya].callbacks.frame.definition_version,1,"frame stable")
        eq(pc.units[keya].callbacks.frame.fn,a.frame,"same old frame")
        eq(pc.units[keyb].callbacks.init.fn,b.init,"same unselected callback")
        eq(pc.units[keyb].definition_version,1,"unselected source not acknowledged")
        for _,key in ipairs(state.order) do
            eq(pc.units[key].unit_ref,state.units[key].unit_ref,"publication preserves the individual Card ref")
            eq(pc.units[key].class_ref,class_ref,"publication preserves the genuine Class ref")
        end
        eq(group(proposed,ClassAdapter),class_group,"callback/helper preparation retains actual Class group")
        eq(observed(proposed,keyb).helper,2,"derived shared observation advances")
        eq(observed(proposed,keyc).other,1,"pending independent observation stays old")
        eq(proposed.loaded_source,source,"baseline unchanged")
        eq(fragment(selected,Card).proposed_group.state.layout,state.layout,"owner preparation retains original layout")
        for class,layout in next,state.layout do
            eq(#pc.layout[class],#layout,"sealed layout length")
            for slot,desc in ipairs(layout) do
                local sealed_desc=pc.layout[class][slot]
                for _,field in ipairs({"kind","name","constructor","perform"}) do
                    eq(sealed_desc[field],desc[field],"sealed original layout field "..field)
                end
                eq(sealed_desc.callbacks.init,desc.callbacks.init,"sealed original init layout")
            end
        end
        for _,name in ipairs(names) do eq(pc.defaults[name],state.defaults[name],"sealed saved default identity") end
        eq(f.capture.snapshot,base,"Seal never installs");eq(state.units[keya].definition_version,1,"base records untouched")
        eq(a.init,f.initial_owners[1].callbacks.init,"no current raw write")
        eq(b.init,f.initial_owners[2].callbacks.init,"no unselected raw write")
        eq(Anchor.Get(entry,"helper"),identities.helper,"no helper cell write")
        local uninstalled_op=copy(selected.operation);uninstalled_op.base_snapshot=proposed
        local uninstalled_fragments={}
        for _,r in ipairs(selected.entries) do
            local candidate=copy(r.fragment);candidate.operation=uninstalled_op
            uninstalled_fragments[#uninstalled_fragments+1]=candidate
        end
        refuse(function() return Files.Propose(uninstalled_op,uninstalled_fragments) end,
            "ownership","uninstalled proposed snapshot not actual baseline")
        local shared=must(prepare(f,source:gsub("counter%+n","counter+n+1"),{keya}))
        local hc,hl,hs=description(shared)
        eq(#cardplan(shared).publications,0,"helper only no wrapper")
        eq(#localplan(shared).cell_writes,1,"helper only one Local write")
        list(fields(hc.cards,"affected"),keya..","..keyb,"shared actual consumers")
        eq(group(hs.proposed_snapshot,Card),group(base,Card),"helper-only preserves whole actual Card group")
        eq(observed(hs.proposed_snapshot,keya).helper,2,"helper-only derived observation")
        local removed=source:gsub("_tmp_sc.frame=function%(self,n%) return alias%(n%) end\n","")
        local deletion=must(prepare(f,removed,{keya}));local dp=cardplan(deletion).publications
        eq(#dp,1,"optional deletion one raw write");eq(dp[1].key,"frame","exact deleted callback")
        eq(dp[1].value,defaults.frame,"exact saved default");eq(dp[1].callback.body,nil,"tombstone has no body")
        list(localplan(deletion).local_names,"counter,helper,pattern","deleted alias no longer demanded")
        local added=source:gsub("table.insert","function _tmp_sc:render() return flag,empty end\ntable.insert",1)
        local addition=must(prepare(f,added,{keya}));local ap=cardplan(addition).publications
        eq(#ap,1,"optional addition one callback");list(ap[1].callback.dependencies,"empty,flag","actual nil/false slots")
        eq(#ap[1].callback.join_plan.joins,2,"two original cells to connect")
        local switched=source:gsub("return pattern%(n%) end","return other(n) end",1):gsub("n%+100","n+200")
        local switch=must(prepare(f,switched,{keya}))
        list(localplan(switch).local_names,"other,alias","changed wrapper selects new provider; unchanged frame keeps alias")
        eq(localplan(switch).cell_writes[1].name,"other","new needed definition selected")
        local misleading=source:gsub("return pattern%(n%) end","local other=9;return pattern(n),other end",1)
        local shadowed=must(prepare(f,misleading:gsub("n%+100","n+200"),{keya}))
        local _,shadowlocals=description(shadowed)
        list(localplan(shadowed).local_names,"counter,helper,pattern,alias","inner shadow not a provider")
        list(fields(shadowlocals.functions,"pending","local:"),"other","shadowed word cannot consume pending Local")
        local stringword=must(prepare(f,source:gsub("return pattern%(n%) end","return pattern(n),'other' end",1),{keya}))
        list(localplan(stringword).local_names,"counter,helper,pattern,alias","string not a capture")
        local v=cardplan(selected).view
        refuse(function() return Versions.Prepare(v,{keya,keya},{}) end,"ownership","duplicate private keys")
        refuse(function() return Versions.Prepare(v,{"missing"},{}) end,"ownership","unknown private key")
        refuse(function() return Versions.Prepare(v,{[2]=keya},{}) end,"ownership","sparse private keys")
        refuse(function() return Guard.Seal({}, {}) end,"ownership","malformed public operation")
        refuse(function() return Guard.Seal(selected.operation,{{}}) end,"ownership","malformed public fragment")
        eq(Files.Validate({}),false,"not a common capture")
        refuse(function() return Source.Build("bad function(") end,"compile","whole source syntax rejected before matching")
        local fixed=must(prepare(f,source.."\nlocal added=1",{keya},true))
        eq(#fixed.dependencies.safe_roots,0,"changed binding set cannot prepare selected root")
        eq(fixed.dependencies.blocked_roots[1].reason.code,"unsupported","fixed local set diagnostic")
        local renamed=must(prepare(f,source:gsub("'A'","'Renamed'"),{keya}))
        eq(cardplan(renamed).view.locations.by_key[keya].status,"located","rename retains correspondence")
        local layout=must(prepare(f,source:gsub("return pattern%(n%) end","return pattern(n) end\n_tmp_sc.perform=true",1),{keya},true))
        check(#cardplan(layout).view.locations.pending>0,"unpublished layout pending")
        refuse(function() return seed_owners(f,{},defaults) end,"ownership","all first-load owners required")
        refuse(function() return seed_owners(f,{f.initial_owners[1],f.initial_owners[1]},defaults) end,"ownership","duplicate owner")
        local bad_owner={class_key="K",slot=2,card=a,callbacks=f.initial_owners[1].callbacks}
        refuse(function() return seed_owners(f,{f.initial_owners[1],bad_owner,f.initial_owners[3]},defaults) end,"ownership","one card cannot own two slots")
        refuse(function() return seed_owners(f,f.initial_owners,{}) end,"ownership","seven defaults required")
        local replacement=function() end
        a.render=replacement
        refuse(function() return prepare(f,source,{keya}) end,"stale","external default replacement")
        a.render=defaults.render
        local genuine=a.init;a.init=replacement
        refuse(function() return prepare(f,source,{keya}) end,"stale","external defined callback replacement")
        refuse(function() return seed_owners(f,f.initial_owners,defaults) end,"stale","cannot substitute first identities")
        a.init=genuine
        eq(joins,0,"all preparation/Seal never join");eq(writes,0,"all preparation/Seal never setupvalue")
        eq(flushes,0,"all preparation/Seal never flush")
        debug.upvaluejoin,debug.setupvalue,_G.jit=saved_join,saved_set,saved.jit
        -- Re-prepare after changing inputs; the old operation cannot be reused.
        selected=must(prepare(f,all,{keya}))
        local receipt=must(publish(f,selected));local first=f.capture.snapshot
        eq(receipt.changed,true,"real changed receipt");eq(receipt.snapshot,first,"receipt actual snapshot")
        eq(first.revision,1,"one common first revision")
        eq(#receipt.owner_deltas,3,"common receipt includes all three actual owners")
        for _,delta in ipairs(receipt.owner_deltas) do
            eq(delta.changed,delta.owner==Local or delta.owner==Card,"only the two writers report installation")
        end
        eq(group(first,ClassAdapter),class_group,"joint Card/Local publication retains Class group")
        eq(observed(first,keya)["class:K"],1,"Class definition stays v1 after joint publication")
        eq(a:init(1),26,"selected wrapper plus helper");eq(b:init(1),16,"old sibling sees shared helper")
        eq(c:init(1),101,"unselected Local old");eq(a:frame(1),5,"alias keeps old function value")
        local rest=must(prepare(f,all,{keyb}));local rc,rl=description(rest)
        list(changes(rest),keyb,"second wrapper still pending before publication")
        list(localplan(rest).local_view.version_view.changed,"other","independent Local still pending")
        eq(#localplan(rest).cell_writes,0,"same helper not rewritten");eq(#cardplan(rest).publications,1,"only second wrapper")
        local second_receipt=must(publish(f,rest));local second=f.capture.snapshot
        for _,delta in ipairs(second_receipt.owner_deltas) do eq(delta.changed,delta.owner==Card,"callback-only exact owner delta") end
        eq(second.revision,2,"second common revision")
        eq(group(second,Local),group(first,Local),"callback-only preserves actual Local group")
        eq(group(second,ClassAdapter),class_group,"callback-only preserves actual Class group")
        eq(b:init(1),36,"second wrapper actually published")
        must(publish(f,must(prepare(f,all,{keyc}))));local third=f.capture.snapshot
        eq(third.revision,3,"third common revision");eq(locals(third).by_name.other.definition_version,2,"unrelated Local advances only now")
        eq(c:init(1),201,"third actual Local update")
        local complete=must(prepare(f,all,{}));list(changes(complete),"","all wrappers adopted")
        list(localplan(complete).local_view.version_view.changed,"","all Local definitions adopted")
        eq(cards(third).units[keya].callbacks.init.definition_version,2,"A version stable on other Apply")
        eq(cards(third).units[keyb].callbacks.init.definition_version,2,"B own callback version")
        eq(cards(third).units[keyc].callbacks.init.definition_version,1,"C helper only keeps wrapper version")
        local old_frame=a.frame
        must(publish(f,must(prepare(f,all:gsub("_tmp_sc.frame=function%(self,n%) return alias%(n%) end\n",""),{keya}))))
        local deleted=f.capture.snapshot
        eq(a.frame,defaults.frame,"deletion actually restores default")
        eq(cards(deleted).units[keya].callbacks.frame.definition_version,2,"deletion callback history")
        eq(old_frame(a,1),5,"escaped old alias closure remains old")
        must(publish(f,must(prepare(f,all,{keya}))));local restored=f.capture.snapshot
        eq(a:frame(1),5,"re-added frame shares original alias cell")
        eq(cards(restored).units[keya].callbacks.frame.definition_version,3,"re-add callback history")
        eq(cards(restored).units[keya].callbacks.init.definition_version,2,"frame changes leave init version")
        local nil_false_source=all:gsub("table.insert","function _tmp_sc:render() return flag,empty end\ntable.insert",1)
        must(publish(f,must(prepare(f,nil_false_source,{keya}))));local nil_false=f.capture.snapshot
        local flag_value,empty_value=a:render();eq(flag_value,false,"old false cell");eq(empty_value,nil,"old nil cell")
        must(Anchor.Set(entry,"flag",true));must(Anchor.Set(entry,"empty",7))
        flag_value,empty_value=a:render();eq(flag_value,true,"false cell external update");eq(empty_value,7,"nil cell external update")
        must(prepare(f,nil_false_source,{keya}));eq(observed(nil_false,keya).helper,2,"ordinary state does not advance definitions")
        local literal=cards(nil_false).units[keya].callbacks.render
        local slots=must(Compose.Upvalues(literal.fn));local flag_slot
        for _,slot in ipairs(slots) do if slot.name=="flag" then flag_slot=slot.index end end
        check(Anchor.Shared(entry,"flag",literal.fn,must(flag_slot)),"physical original state cell")
        local counter_value=Anchor.Get(entry,"counter")
        for i=1,20000 do a:init(i) end -- ordinary JIT, no -joff
        must(Anchor.Set(entry,"counter",counter_value+10))
        eq(a:init(1),36,"hot old wrapper sees counter");eq(b:init(1),46,"hot indirect wrapper sees counter")
        local detached=must(Compose.Create(literal.body,nil,literal.visible,{form="expression"}))
        local captured_slot=slots[1]
        debug.upvaluejoin(literal.fn,captured_slot.index,detached.fn,captured_slot.index)
        refuse(function() return prepare(f,nil_false_source,{keya}) end,"stale","physical callback rejoin")
        must(Compose.Join(must(Compose.Plan(literal.fn,entry))))
        must(prepare(f,nil_false_source,{keya}))
        -- A stale operation/old common baseline cannot resume after publication.
        local old_fragments={};for _,r in ipairs(selected.entries) do old_fragments[#old_fragments+1]=r.fragment end
        refuse(function() return Guard.Seal(selected.operation,old_fragments) end,"ownership","old installed baseline cannot prepare again")
        -- Accepted single-card blocks stay contiguous; scope still comes from the full source.
        local point_source=table.concat({
            "local late=false","_editor_class['K']=Class(boss)",
            "_editor_class['K'].cards={}","_tmp_sc=boss.card.New('Late',1,2,3,100)",
            "function _tmp_sc:init() return late end",
            "table.insert(_editor_class['K'].cards,_tmp_sc)",
        },"\n")
        local point=fixture(point_source);local point_base=point.capture.snapshot
        local point_cb=cards(point_base).units[keya].callbacks.init
        list(point_cb.visible,"late","callback sees the pre-card declaration")
        list(point_cb.dependencies,"late","actual late state capture")
        local point_layout=point.initial_match.by_class.K.layout
        list(point_layout[1].locals,"late","constructor visibility is an ordered name list")
        eq(Source.Owns(point.entry.source,point_layout[1].callback_syntax.init),true,
            "callback syntax retains its complete original source")
        check(point_layout[1].callback_points.init.first>0,"explicit callback source point")
        local point_new=point_source:gsub("return late end","return late,1 end")
        local point_p=must(prepare(point,point_new,{keya}))
        eq(#cardplan(point_p).publications,1,"late local callback change prepared")
        eq(#cardplan(point_p).publications[1].callback.join_plan.joins,1,"late uses original anchor donor")
        must(publish(point,point_p))
        eq(point.classes.K.cards[1]:init(),false,"pre-card false cell after publication")
        must(Anchor.Set(point.entry,"late",9))
        eq(point.classes.K.cards[1]:init(),9,"pre-card original state cell remains shared")
        must(prepare(point,point_new,{keya}))
        -- Preserve the old interrupted input as an explicit whole-discovery refusal.
        local interrupted=point_source:gsub("local late=false\n","")
            :gsub("function _tmp_sc:init","local late=false\nfunction _tmp_sc:init",1)
        local before_interrupted=point.capture.snapshot
        local before_callback=point.classes.K.cards[1].init
        local rejected,interrupted_error=prepare(point,interrupted,{keya})
        refuse(function() return rejected,interrupted_error end,"unsupported","local between constructor and callback")
        eq(interrupted_error and interrupted_error.phase,"match","interrupted card refuses during shared discovery")
        eq(interrupted_error and interrupted_error.message,"card callback is outside a matched single-card definition",
            "orphan callback is rejected rather than silently skipped")
        eq(point.capture.snapshot,before_interrupted,"interrupted candidate preserves actual snapshot")
        eq(point.classes.K.cards[1].init,before_callback,"interrupted candidate preserves live callback")
        eq(Anchor.Get(point.entry,"late"),9,"interrupted candidate never replays local state")
        must(prepare(point,point_new,{keya}))
        -- Moving the declaration after the complete card keeps syntax valid while
        -- changing callback visibility; selection must still refuse that capture drift.
        local moved=point_source:gsub("local late=false\n","").."\nlocal late=false"
        local moved_f=fixture(point_source);local moved_base=moved_f.capture.snapshot
        local unselected=must(prepare(moved_f,moved,{}));local uc=description(unselected)
        list(changes(unselected),keya,"same body plus lexical drift is a pending definition")
        list(fields(uc.cards,"pending"),keya,"unselected lexical drift stays pending")
        eq(next(cardplan(unselected).view.probes),nil,"unselected drift constructs no callback")
        eq(seal(unselected).proposed_snapshot,moved_base,"unselected drift never installs")
        local moved_p=must(prepare(moved_f,moved,{keya},true))
        eq(#moved_p.dependencies.safe_roots,0,"unchanged body moved before local cannot be selected")
        eq(#moved_p.dependencies.blocked_roots,1,"one exact binding drift refusal")
        eq(moved_p.dependencies.blocked_roots[1].reason.code,"unsupported","definition-point drift diagnostic")
        eq(#cardplan(moved_p).raw_writes,0,"binding drift no raw writes")
        eq(#localplan(moved_p).cell_writes,0,"binding drift no cell writes")
        eq(moved_f.capture.snapshot,moved_base,"binding drift leaves actual snapshot")
        local changed_moved=must(prepare(moved_f,moved:gsub("return late end","return late,2 end"),{keya},true))
        eq(#changed_moved.dependencies.safe_roots,0,"changed body plus lexical drift also blocked")
        eq(changed_moved.dependencies.blocked_roots[1].reason.code,"unsupported","changed body lexical refusal")
        local bom=fixture("\239\187\191"..point_source)
        list(cards(bom.capture.snapshot).order,keya,"BOM first-load layout")
        local bom_p=must(prepare(bom,"\239\187\191"..point_source,{keya}))
        list(changes(bom_p),"","BOM offset equality")
        local future=fixture(moved)
        list(cards(future.capture.snapshot).units[keya].callbacks.init.dependencies,"","future local remains global")
        local future_p=must(prepare(future,moved:gsub("return late end","return late,2 end"),{keya}))
        eq(#cardplan(future_p).publications[1].callback.join_plan.joins,0,"future global never silently captured")

        local cross_source=table.concat({
            "local function shared(n) return n+1 end","_editor_class['K']=Class(boss)","_editor_class['K'].cards={}",
            "_tmp_sc=boss.card.New('One',1,2,3,100)","function _tmp_sc:init(n) return shared(n) end",
            "table.insert(_editor_class['K'].cards,_tmp_sc)","_editor_class['L']=Class(boss)","_editor_class['L'].cards={}",
            "_tmp_sc=boss.card.New('Two',1,2,3,100)","function _tmp_sc:init(n) return shared(n)+10 end",
            "table.insert(_editor_class['L'].cards,_tmp_sc)",
        },"\n")
        local cross=fixture(cross_source);local keyl="card:1:L:1"
        list(cards(cross.capture.snapshot).order,keya..","..keyl,"cross-class discovery")
        local cross_new=cross_source:gsub("n%+1 end","n+2 end"):gsub("shared%(n%)%+10","shared(n)+20")
        local cross_p=must(prepare(cross,cross_new,{keya}));local cc,cl=description(cross_p)
        list(localplan(cross_p).local_names,"shared","cross-class shared provider")
        list(fields(cc.cards,"pending"),keyl,"other class wrapper pending")
        list(fields(cc.cards,"affected"),keya..","..keyl,"actual cross-class shared impact")
        eq(#cardplan(cross_p).publications,0,"unchanged selected wrapper reused")
        local cross_card=group(cross.capture.snapshot,Card)
        must(publish(cross,cross_p))
        eq(group(cross.capture.snapshot,Card),cross_card,"helper-only cross-class retains Card group")
        eq(cross.classes.K.cards[1]:init(1),3,"current old closure updated")
        eq(cross.classes.L.cards[1]:init(1),13,"unselected old closure shared update")
        local cross_rest=must(prepare(cross,cross_new,{}));list(changes(cross_rest),keyl,"cross-class pending survives")
        local pending_graph=cross_new:gsub("shared%(n%)%+20","999"):gsub("n%+2 end","n+3 end")
        local pending_p=must(prepare(cross,pending_graph,{keya}));local pending_cards=description(pending_p)
        list(fields(pending_cards.cards,"affected"),keya..","..keyl,"pending capture removal is not installed")

        local recursive_source=table.concat({
            "local f,g","f=function(n) if n==0 then return 0 end return g(n-1)+1 end",
            "g=function(n) if n==0 then return 0 end return f(n-1)+1 end",
            "_editor_class['K']=Class(boss)","_editor_class['K'].cards={}","_tmp_sc=boss.card.New('Loop',1,2,3,100)",
            "function _tmp_sc:init(n) return f(n) end","table.insert(_editor_class['K'].cards,_tmp_sc)",
        },"\n")
        local recursive=fixture(recursive_source)
        local recursive_p=must(prepare(recursive,recursive_source:gsub("%+1 end","+2 end"),{keya}))
        list(localplan(recursive_p).local_names,"f,g","resolvable provider cycle selected")
        eq(#cardplan(recursive_p).publications,0,"cycle update does not rebuild wrapper")
        must(publish(recursive,recursive_p))
        eq(recursive.classes.K.cards[1]:init(6),12,"real recursive cycle publication")
        eq(cards(recursive.capture.snapshot).units[keya].definition_version,1,"recursive wrapper version unchanged")
        eq(observed(recursive.capture.snapshot,keya).f,2,"derived recursive f version")
        eq(observed(recursive.capture.snapshot,keya).g,2,"derived recursive g version")

        -- Genuine first-load identity and malformed-owner seams, not fabricated ledgers.
        local audit=fixture(source);local audit_base=audit.capture.snapshot
        local owners=audit.initial_owners
        local missing_cb=copy(owners[1]);missing_cb.callbacks=copy(missing_cb.callbacks);missing_cb.callbacks.after=nil
        refuse(function() return seed_owners(audit,{missing_cb,owners[2],owners[3]},defaults) end,"stale","all seven first callback identities required")
        local extra_cb=copy(owners[1]);extra_cb.callbacks=copy(extra_cb.callbacks);extra_cb.callbacks.update=defaults.frame
        refuse(function() return seed_owners(audit,{extra_cb,owners[2],owners[3]},defaults) end,"unsupported","unknown callback refused")
        local extra_owner=copy(owners[1]);extra_owner.slot=4
        refuse(function() return seed_owners(audit,{owners[1],owners[2],owners[3],extra_owner},defaults) end,"ownership","unknown extra combat owner")
        local wrong=copy(owners[1]);wrong.class_key=""
        refuse(function() return seed_owners(audit,{wrong},defaults) end,"ownership","empty owner class")
        wrong=copy(owners[1]);wrong.slot=1.5
        refuse(function() return seed_owners(audit,{wrong},defaults) end,"ownership","fractional owner slot")
        wrong.slot=math.huge
        refuse(function() return seed_owners(audit,{wrong},defaults) end,"ownership","infinite owner slot")
        refuse(function() return seed_owners(audit,{[2]=owners[1]},defaults) end,"ownership","sparse owner array")
        local metamethods=0
        local function trap() metamethods=metamethods+1;error("metamethod ran") end
        refuse(function() return seed_owners(audit,setmetatable({},{__index=trap}),defaults) end,"ownership","owner container metatable")
        refuse(function() return seed_owners(audit,owners,setmetatable({},{__index=trap})) end,"ownership","default container metatable")
        local audit_p,audit_d=prepare(audit,source,{keya});must(audit_p,audit_d)
        refuse(function() return Versions.Prepare(cardplan(audit_p).view,setmetatable({},{__index=trap}),{}) end,"ownership","selection container metatable")
        local raw_target=owners[1].card
        setmetatable(raw_target,{__newindex=trap})
        refuse(function() return prepare(audit,source,{keya}) end,"ownership","published target metatable")
        setmetatable(raw_target,nil);eq(metamethods,0,"refusals invoke no table handlers")
        local changed_defaults=copy(defaults);changed_defaults.before=function() end
        refuse(function() return seed_owners(audit,owners,changed_defaults) end,"stale","source-absent default identity")
        local wrong_capture=function() return 7 end
        local original_init=raw_target.init;raw_target.init=wrong_capture
        local substituted=copy(owners[1]);substituted.callbacks=copy(substituted.callbacks);substituted.callbacks.init=wrong_capture
        refuse(function() return seed_owners(audit,{substituted,owners[2],owners[3]},defaults) end,"stale","matching live replacement lacks genuine source captures")
        raw_target.init=original_init
        local preservation=must(prepare(audit,source:gsub("counter=4","counter=99"),{keya}))
        local preserve_cards,preserve_locals,preserve_sealed=description(preservation)
        eq(#preserve_locals.initializers,1,"initializer diagnostic retained")
        list(changes(preservation),"","initializer not a callback publication")
        eq(preserve_sealed.proposed_snapshot,audit_base,"initializer never acknowledged")
        eq(Anchor.Get(audit.entry,"counter"),4,"initializer never replayed")
        local no_current=must(prepare(audit,all,{}));local nc,nl,ns=description(no_current)
        list(fields(nc.cards,"pending"),keya..","..keyb,"empty roots retain all changed wrappers")
        list(fields(nl.functions,"pending","local:"),"helper,other","empty roots retain changed Local definitions")
        eq(#fragment(no_current,Card).joins,0,"empty roots no callback joins")
        eq(#localplan(no_current).joins,0,"empty roots no Local joins")
        eq(#localplan(no_current).cell_writes,0,"empty roots no cell writes")
        eq(#cardplan(no_current).publications,0,"empty roots no callbacks")
        eq(ns.proposed_snapshot,audit_base,"empty roots no common revision")
        local batch=must(prepare(audit,all,{keyb,keya}));local bc,bl=description(batch)
        list(cardplan(batch).keys,keya..","..keyb,"batch normalized to original source order")
        eq(#cardplan(batch).publications,2,"two explicitly selected wrappers")
        eq(#localplan(batch).cell_writes,1,"shared helper writes deduplicated")
        list(fields(bl.functions,"pending","local:"),"other","batch retains unrelated function")
        -- Version validation belongs to the one common capture, not Card's private state.
        local broken=copy(audit.capture);broken.snapshot=copy(audit_base);broken.snapshot.revision=-1
        refuse(function() return Files.Publication(broken) end,"ownership","invalid common revision")
        broken=copy(audit.capture);broken.snapshot=copy(audit_base);broken.snapshot.anchor=function() end
        refuse(function() return Files.Publication(broken) end,"ownership","different common anchor")
        audit.entry.missing=true
        refuse(function() return prepare(audit,source,{keya}) end,"stale","missing source cannot prepare")
        audit.entry.missing=false;must(prepare(audit,source,{keya}))
        -- No absent-join compatibility shim: real capability failure is a final
        -- mechanical gate, even when a complete preparation has already succeeded.
        local capability=must(prepare(audit,all,{keya}));local cap_sealed=seal(capability)
        debug.upvaluejoin=nil
        local cap_ok,cap_error=Guard.Mechanical(cap_sealed,audit.capture,audit.refresh())
        debug.upvaluejoin=saved_join
        eq(cap_ok,nil,"real join capability withdrawn")
        eq(cap_error and cap_error.code,"capability","mechanical capability refusal")
    end)
    debug.upvaluejoin,debug.setupvalue=saved_join,saved_set
    for _,controller in ipairs(controllers) do eq(controller:Release(),true,"common controller released") end
    if environment then environment:Restore() end
    for _,name in ipairs(globals) do rawset(_G,name,saved[name]) end
    if not ok then error(type(problem)=="string" and problem or "CardVersionsSpec opaque failure",0) end
    for _,label in ipairs(failures) do print("FAIL CardVersions: "..label) end
    return {passed=passed,failed=failed}
end
return M
