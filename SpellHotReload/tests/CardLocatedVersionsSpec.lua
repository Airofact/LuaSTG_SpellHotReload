-- Located CardVersions reports; only miniature genuine first-load fixtures run.
-- Candidate initializers/bodies never run during discovery/compare/select/Next.
local M={}
function M.run()
    local Cards=require("SpellHotReload.Adapters.Card.CardVersions")
    local Target=require("SpellHotReload.Adapters.Card.CardTarget")
    local Driver=require("SpellHotReload.Pipeline.Driver")
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local Load=require("SpellHotReload.Load.AnchorLoad")
    local Capture=require("SpellHotReload.Load.LoadVersions")
    local Guard=require("SpellHotReload.Apply.CommitCheck")
    local Commit=require("SpellHotReload.Apply.CardCommit")
    local Anchor=require("SpellHotReload.Load.Anchor")
    local passed,failed,failures=0,0,{}
    local function eq(a,b,label)
        if rawequal(a,b) then passed=passed+1
        else failed=failed+1;failures[#failures+1]=label end
    end
    local function list(a,expected,label) eq(table.concat(a,","),expected,label) end
    local function must(v,e) assert(v,type(e)=="table" and e.message or e);return v end
    local function refuse(fn,code,label)
        local v,e=fn()
        eq(v,nil,label.." refused");eq(type(e),"table",label.." structured")
        eq(e and e.code,code,label.." code")
    end
    local function copy(v) local r={};for k,x in next,v do r[k]=x end;return r end
    local callbacks={"before","init","frame","render","beforedel","del","after"}
    local defaults={};for _,n in ipairs(callbacks) do defaults[n]=function() return "default" end end
    local saved={}
    for _,n in ipairs({"boss","_editor_class","_tmp_sc","LOCATED_EFFECT","jit"}) do saved[n]=rawget(_G,n) end
    local real_join,real_set=debug.upvaluejoin,debug.setupvalue
    if not real_join then debug.upvaluejoin=function() error("presence fixture only") end end
    local function scoped(controller,fn)
        local ran,value,err=controller:Run(fn)
        eq(ran,true,"trusted scope completed")
        return value,err
    end
    local serial,effects=0,0
    local function source(labels,move,opts)
        opts=opts or {}
        local lines={"local state="..(opts.state or 4),
            "local function helper(n) return state+n+"..(opts.helper or 0).." end",
            "local function other(n) return n+"..(opts.other or 100).." end",
            "LOCATED_EFFECT()"}
        local function add_class(key,items,with_move)
            lines[#lines+1]="_editor_class["..string.format("%q",key).."].cards={}"
            if with_move then
                lines[#lines+1]="table.insert(_editor_class["..string.format("%q",key).."].cards,boss.move.New(0,0,1))"
            end
            for _,label in ipairs(items) do
                local bump=({A=10,B=20,C=30,Side=50})[label] or 40
                if opts.bumps and opts.bumps[label] then bump=opts.bumps[label] end
                lines[#lines+1]="_tmp_sc=boss.card.New("..string.format("%q",label)..",1,2,3,4)"
                local callee=key=="L" and "other" or "helper"
                lines[#lines+1]="function _tmp_sc:init(n) return "..callee.."(n)+"..bump.." end"
                if not opts.no_frame then lines[#lines+1]="function _tmp_sc:frame() return state end" end
                lines[#lines+1]="table.insert(_editor_class["..string.format("%q",key).."].cards,_tmp_sc)"
            end
        end
        add_class("K",labels,move)
        if not opts.no_l then add_class("L",opts.l or {"Side"},false) end
        return (opts.bom and "\239\187\191" or "")..table.concat(lines,"\n")
    end
    local function fixture(labels,slot,move)
        _editor_class={K={},L={}}
        LOCATED_EFFECT=function() effects=effects+1 end
        boss={card={New=function(label)
            local card={name=label,is_combat=true}
            for _,n in ipairs(callbacks) do card[n]=defaults[n] end
            return card
        end},move={New=function() return {is_combat=false} end}}
        serial=serial+1
        local bytes=source(labels,move)
        local entry=must(Load.Capture(bytes,{name="Located_Boss.lua",
            capability={getupvalue=true,setupvalue=true,upvaluejoin=true}}))
        entry.file="Located_Boss.lua"
        local capture=must(Capture.Capture(entry,"located:"..serial,_editor_class,defaults))
        local driver=Driver.New();assert(driver:RegisterDiscovery(Card))
        local live={capture=capture,snapshot=capture.snapshot,entry=entry,
            classes=_editor_class,session_id=capture.snapshot.session_id}
        local function binding(at)
            local slots=live.classes.K.cards
            local names={};for i,card in ipairs(slots) do names[i]=card.name or "" end
            return {class_key="K",slot=at or slot,card=slots[at or slot],
                name=slots[at or slot].name,names=names,mode=move and "debug" or "practice",
                include_previous=false}
        end
        local function discover(content)
            local base=capture.snapshot
            live.snapshot,live.content,live.binding=base,content,binding()
            local snapshot=must(driver:Discover(entry.file,content,{session_id=base.session_id,
                registry_entry=entry,loaded_source=base.loaded_source,published_units=base,
                base_revision=base.revision,candidate_generation=7})).snapshot
            return snapshot
        end
        local function report(content,at)
            local snapshot=discover(content)
            live.binding=binding(at)
            local target=must(Target.Resolve(live.binding,capture,live))
            local location=must(Target.LocateDiscovery(target,snapshot,live.binding,capture,live))
            return must(Cards.CompareLocated(capture.snapshot,location,live.binding,capture,live)),location
        end
        return {capture=capture,live=live,binding=binding,discover=discover,report=report,entry=entry}
    end
    local ok,problem=pcall(function()
        local f=fixture({"A","B","C"},3,true)
        local base=f.capture.snapshot
        local bytes=source({"B"},true,{helper=7,bumps={B=25},no_l=true,no_frame=true,state=900})
        local joins,writes,flushes=0,0,0
        debug.upvaluejoin=function() joins=joins+1;error("premature join") end
        debug.setupvalue=function() writes=writes+1;error("premature write") end
        jit={flush=function() flushes=flushes+1;error("premature flush") end}
        local before_effect=effects
        local report,location=f.report(bytes)
        local a,b,c,side="card:1:K:2","card:1:K:3","card:1:K:4","card:1:L:1"
        eq(report.location,location,"same explicit proof")
        eq(report.discovery,location.discovery,"full discovery retained")
        eq(report.content,bytes,"full raw candidate retained")
        eq(report.by_key[b].source_slot,2,"root uses shifted candidate descriptor")
        eq(report.by_key[b].source_key,"card:K","source key is class coordinate")
        eq(report.by_key[b].previous,base.units[b],"stable published identity")
        eq(report.by_key[a].previous,base.units[a],"unmapped owner retained")
        eq(report.by_key[a].action,"unmapped","cropping is not proven deletion")
        eq(report.by_key[c].action,"unmapped","suffix owner not guessed")
        eq(report.by_key[side].action,"source-absent","absent class explicit")
        list(report.unmapped,a..","..c..","..side,"all old unmapped owners included")
        eq(#report.tombstones,1,"source tombstone count")
        eq(report.tombstones[1].previous,base.units[side],"tombstone keeps published unit")
        eq(report.tombstones[1].definition_version,1,"tombstone keeps source version")
        eq(report.tombstones[1].action,"restart-required","no live deletion action")
        eq(#report.unowned,0,"current candidate root claimed")
        local selection=must(Cards.Select(report,{b}))
        list(selection.selected,b,"only root selected")
        list(selection.pending,a..","..c..","..side,"unknown owners remain pending")
        list(selection.functions.selected,"helper","only necessary shared definition")
        eq(#selection.publications,2,"init edit and optional frame deletion only")
        eq(selection.publications[1].target,base.units[b].card,"publish original live object")
        eq(selection.publications[2].value,defaults.frame,"optional deletion restores default")
        eq(selection.location,location,"proof carried to commit")
        eq(#selection.tombstones,1,"tombstone carried")
        eq(#selection.pending_sources,0,"no unowned sources")
        eq(selection.report.discovery,report.discovery,"selection retains complete candidate")
        list(selection.affected,a..","..b..","..c,"unmapped old consumers receive helper impact")
        local next_state=must(Cards.Next(selection))
        list(next_state.order,table.concat(base.order,","),"no owners dropped")
        eq(next_state.layout,base.layout,"loaded layout immutable")
        eq(next_state.loaded_source,base.loaded_source,"loaded bytes immutable")
        eq(next_state.units[b].slot,3,"published/restart slot never candidate index")
        eq(next_state.units[b].definition_version,2,"actual wrapper edit advances")
        eq(next_state.units[a].definition_version,1,"unmapped wrapper version retained")
        eq(next_state.units[c].definition_version,1,"other cropped wrapper retained")
        eq(next_state.units[side].definition_version,1,"absent source wrapper retained")
        eq(next_state.units[a].callbacks.init.fn,base.units[a].callbacks.init.fn,"unmapped live identity retained")
        eq(next_state.units[a].observed.helper,2,"unmapped helper observation advances")
        eq(next_state.units[side].observed.other,1,"independent observation unchanged")
        eq(f.capture.snapshot,base,"Next not installed")
        eq(effects,before_effect,"candidate initializer never executed")
        eq(joins,0,"no early joins");eq(writes,0,"no early cell writes");eq(flushes,0,"no early flush")
        refuse(function() return Cards.Select(report,{a}) end,"ambiguous","unmapped selection")
        refuse(function() return Cards.CompareDiscovery(base,report.discovery) end,"ambiguous","old fixed entry remains strict")
        refuse(function() return Cards.Compare(base,bytes:gsub("900","901")) end,"ambiguous","legacy gsub multi-return remains content")
        local empty=must(Cards.Select(report,{}))
        list(empty.pending,a..","..b..","..c..","..side,"empty selection keeps all pending")
        eq(Cards.Next(empty),base,"empty Next no revision")
        debug.upvaluejoin=real_join or function() error("presence fixture only") end
        debug.setupvalue=real_set;jit=saved.jit

        local cases={
            {{"B"},2,true,{"A","B","C"},true,3,"debug to full"},
            {{"A","B","C"},3,true,{"B"},true,2,"full to debug"},
            {{"A","B"},2,false,{"A","Renamed"},false,2,"rename"},
            {{"Same","Same"},2,false,{"Same","Same"},false,2,"duplicate exact slot"},
            {{"A",""},2,false,{"A","","Suffix"},false,2,"unnamed head"},
            {{""},2,true,{"Prefix",""},true,3,"unnamed reverse"},
            {{"A","B"},2,false,{"A","B"},false,2,"BOM",true},
        }
        for _,case in ipairs(cases) do
            f=fixture(case[1],case[2],case[3])
            base=f.capture.snapshot
            report,location=f.report(source(case[4],case[5],{bom=case[8],helper=8}))
            local key="card:1:K:"..case[2]
            selection=must(Cards.Select(report,{key}))
            eq(report.by_key[key].source_slot,case[6],case[7].." candidate index")
            eq(selection.roots[1],key,case[7].." original root")
            eq(selection.location.target.slot,case[2],case[7].." original restart index")
            eq(selection.discovery,location.discovery,case[7].." full discovery")
            eq(f.capture.snapshot,base,case[7].." no install")
            eq(report.by_key[key].previous.card,base.units[key].card,case[7].." actual owner")
            eq(must(Cards.Next(selection)).units[key].slot,case[2],case[7].." Next stable slot")
            if case[7]=="debug to full" then
                eq(#report.unowned,2,"prefix and suffix unowned")
                eq(#selection.pending_sources,2,"both unowned candidates pending")
                local pending_source=selection.pending_sources[1] or {}
                eq(pending_source.source_key,"card:K","pending source class coordinate")
                eq(pending_source.candidate_slot,2,"unowned candidate slot")
                eq(pending_source.descriptor,report.discovery.by_key["card:K"].unit.context.layout[2],
                    "unowned original descriptor")
                eq(pending_source.action,"restart-required","unowned not publishable")
                eq(#selection.publications,0,"helper-only does not publish root")
                eq(#must(Cards.Next(selection)).order,#base.order,"no new owners seeded")
            end
        end

        -- Changed non-current classes are not name-matched or silently adopted.
        f=fixture({"A","B"},2,false);base=f.capture.snapshot
        report,location=f.report(source({"A","B"},false,{l={"Side","Extra"},helper=2}))
        selection=must(Cards.Select(report,{"card:1:K:2"}))
        eq(report.by_key[side].action,"unmapped","other changed class not name-guessed")
        list(selection.pending,side,"unproven other class pending")
        eq(#selection.pending_sources,2,"all other-class candidate cards unowned")
        eq((selection.pending_sources[1] or {}).source_key,"card:L","other candidate class retained")
        eq(#must(Cards.Next(selection)).order,#base.order,"no other-class live owners seeded")
        local old_side=base.units[side].card.init
        rawset(base.units[side].card,"init",function() end)
        refuse(function() return Cards.CompareLocated(base,location,f.live.binding,f.capture,f.live) end,
            "stale","unmapped raw callback also validated")
        rawset(base.units[side].card,"init",old_side)
        if real_join then
            local function index(fn,wanted)
                for i=1,100 do local name=debug.getupvalue(fn,i);if name==wanted then return i end end
                error("fixture capture absent")
            end
            local other=function() return 0 end
            local function foreign() return other end
            real_join(old_side,index(old_side,"other"),foreign,index(foreign,"other"))
            refuse(function() return Cards.CompareLocated(base,location,f.live.binding,f.capture,f.live) end,
                "stale","unmapped callback sharing also validated")
        end

        -- Fixed classes retain full semantic pending even though only current root can publish.
        f=fixture({"A","B"},1,false);base=f.capture.snapshot
        bytes=source({"A","B"},false,{helper=3,bumps={A=15,B=25},other=200})
        report,location=f.report(bytes)
        local ka,kb="card:1:K:1","card:1:K:2"
        eq(report.by_key[kb].changed,true,"mapped sibling edit detected")
        refuse(function() return Cards.Select(report,{kb}) end,"ambiguous","unproven current binding for sibling")
        selection=must(Cards.Select(report,{ka}))
        list(selection.pending,kb,"mapped sibling edit pending")
        list(selection.functions.pending,"other","independent local edit pending")
        local saved_raw=base.units[kb].card.init
        rawset(base.units[kb].card,"init",function() end)
        refuse(function() return Cards.CompareLocated(base,location,f.live.binding,f.capture,f.live) end,
            "stale","all unselected callbacks validated")
        rawset(base.units[kb].card,"init",saved_raw)
        local bad_location=copy(location);bad_location.candidate_slot=1+location.candidate_slot
        refuse(function() return Cards.CompareLocated(base,bad_location,f.live.binding,f.capture,f.live) end,
            "stale","tampered source mapping")
        local wrong=copy(base)
        refuse(function() return Cards.CompareLocated(wrong,location,f.live.binding,f.capture,f.live) end,
            "stale","wrong publication snapshot")
        f.live.content=bytes.."\n"
        refuse(function() return Cards.CompareLocated(base,location,f.live.binding,f.capture,f.live) end,
            "stale","fresh candidate bytes")
        f.live.content=bytes
        local changed_binding=copy(f.live.binding);changed_binding.include_previous=true
        refuse(function() return Cards.CompareLocated(base,location,changed_binding,f.capture,f.live) end,
            "stale","changed restart context")
        f.live.binding=changed_binding
        refuse(function() return Guard.Check(selection,f.capture,f.live) end,"stale","commit root proof rechecked")
        f.live.binding=nil
        refuse(function() return Guard.Check(selection,f.capture,f.live) end,"unsupported","fresh binding required")
        f.live.binding=f.binding()
        eq(Guard.Check(selection,f.capture,f.live),true,"compatible with commit preflight")
        local saved_name=base.units[ka].card.name
        base.units[ka].card.name="External"
        refuse(function() return Guard.Check(selection,f.capture,f.live) end,"stale","commit live name changed")
        base.units[ka].card.name=saved_name
        if not real_join then
            debug.upvaluejoin=nil
            refuse(function() return Guard.Check(selection,f.capture,f.live) end,"capability","Lua51 cannot commit shared cells")
            debug.upvaluejoin=function() error("presence fixture only") end
        end

        if real_join then
            -- Real LuaJIT atomic kernel, not a manual or value-injection publication.
            f=fixture({"A","B","C"},3,true);base=f.capture.snapshot
            bytes=source({"B"},true,{helper=7,bumps={B=25},no_l=true,no_frame=true})
            report,location=f.report(bytes)
            selection=must(Cards.Select(report,{b}))
            local controller=must(Commit.New(base.session_id))
            local original_a,original_b=base.units[a].card.init,base.units[b].card.init
            local receipt=must(scoped(controller,function(token)
                return controller:Commit(token,selection,f.capture,f.live)
            end))
            eq(receipt.changed,true,"real transaction changed")
            eq(receipt.snapshot,f.capture.snapshot,"actual snapshot installed")
            eq(f.capture.snapshot.revision,1,"one aggregate transaction")
            eq(base.units[a].card.init,original_a,"unmapped wrapper not replaced")
            eq(base.units[b].card.init==original_b,false,"current wrapper replaced")
            eq(base.units[a].card:init(1),22,"unmapped callback sees shared helper")
            eq(base.units[b].card:init(1),37,"shifted current callback body used")
            eq(base.units[b].card.frame,defaults.frame,"actual default restored")
            eq(base.units[a].card.frame(),4,"state unchanged")
            eq(Anchor.Get(f.entry,"state"),4,"anchor state retained")
            report,location=f.report(bytes)
            selection=must(Cards.Select(report,{b}))
            eq(#selection.publications,0,"repeat uses actual wrapper baseline")
            eq(#selection.writes,0,"repeat uses actual helper baseline")
            list(selection.pending,a..","..c..","..side,"repeat never swallows unknown owners")
            local same_snapshot=f.capture.snapshot
            receipt=must(scoped(controller,function(token)
                return controller:Commit(token,selection,f.capture,f.live)
            end))
            eq(receipt.changed,false,"repeat no spurious revision")
            eq(f.capture.snapshot,same_snapshot,"repeat retains actual snapshot")
            -- Return to full candidate: prior root remains published; other wrappers still old.
            bytes=source({"A","B","C"},true,{helper=7,bumps={A=15,B=25},no_frame=true})
            report,location=f.report(bytes,2)
            selection=must(Cards.Select(report,{a}))
            eq(report.by_key[b].changed,false,"previous partial publication not forgotten")
            eq(report.by_key[a].changed,true,"previously cropped wrapper edit still available")
            receipt=must(scoped(controller,function(token)
                return controller:Commit(token,selection,f.capture,f.live)
            end))
            eq(f.capture.snapshot.revision,2,"second independent transaction")
            eq(f.capture.snapshot.units[a].definition_version,2,"second selected wrapper advances")
            eq(f.capture.snapshot.units[b].definition_version,2,"first wrapper not re-advanced")
            eq(base.units[a].card:init(1),27,"second card newly published")
            list(selection.pending,c..","..side,"other full candidate wrappers remain pending")
            must(controller:Release())

            -- Flush callback changes only binding scalars: second Guard must refuse pre-mutation.
            f=fixture({"A","B"},1,false);base=f.capture.snapshot
            report=f.report(source({"A","B"},false,{helper=9,bumps={A=15}}))
            selection=must(Cards.Select(report,{ka}))
            controller=must(Commit.New(base.session_id))
            local old_jit=jit
            jit={flush=function() f.live.binding.include_previous=true end}
            refuse(function() return scoped(controller,function(token)
                return controller:Commit(token,selection,f.capture,f.live)
            end) end,"stale","post-flush current proof")
            jit=old_jit
            eq(f.capture.snapshot,base,"post-flush no version install")
            eq(base.units[ka].card.init,selection.publications[1].before,"post-flush no raw publication")
            eq(Anchor.Get(f.entry,"helper"),base.functions.units.helper.fn,"post-flush no cell write")
            must(controller:Release())
        end
    end)
    debug.upvaluejoin,debug.setupvalue=real_join,real_set
    for n,v in next,saved do rawset(_G,n,v) end
    for _,n in ipairs({"boss","_editor_class","_tmp_sc","LOCATED_EFFECT","jit"}) do
        if saved[n]==nil then rawset(_G,n,nil) end
    end
    if not ok then failed=failed+1;failures[#failures+1]="uncaught: "..tostring(problem) end
    print(string.format("CardLocatedVersionsSpec: %d passed / %d failed",passed,failed))
    for _,label in ipairs(failures) do print("  FAIL "..label) end
    return {passed=passed,failed=failed,failures=failures}
end
return M
