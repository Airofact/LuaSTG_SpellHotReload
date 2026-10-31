local Planning=require("SpellHotReload.tests.PlanningFixture")
-- Synthetic first-load ownership only; never game/generated source.
-- Genuine common capture and LuaJIT capabilities; no candidate chunk executes.
local M={}
local serial=0
function M.run(opts)
    opts=opts or {}
    local Target=opts.target or require("SpellHotReload.Adapters.Card.CardTarget")
    local Load=require("SpellHotReload.Adapters.Class.ClassLoad")
    local ClassFixture=require("SpellHotReload.tests.ClassFixture")
    local environment
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local Local=require("SpellHotReload.Adapters.Local.Local")
    local Files=require("SpellHotReload.Pipeline.FileVersions")
    local Source=require("SpellHotReload.Source.FileAnalysis")
    local Anchor=require("SpellHotReload.Load.Anchor")
    local Compose=require("SpellHotReload.Source.Compose")
    local Tx=require("SpellHotReload.Apply.FileCommit")
    local controllers={}
    local function state(capture)
        local group,err=Files.Owner(capture,Card);assert(group,type(err)=="table" and err.message or err)
        return group.state
    end
    local passed,failed,failures=0,0,{}
    local function test(value,label)
        if value then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end
    end
    local function eq(a,b,label) test(rawequal(a,b),label) end
    local function must(value,err) assert(value,type(err)=="table" and err.message or err);return value end
    local function copy(value) local out={} for k,v in next,value do out[k]=v end return out end
    local saved={}
    for _,key in ipairs({"boss","_editor_class","_tmp_sc","_ct_runs","lstg","_sc_table","_boss","IsValid"}) do saved[key]=rawget(_G,key) end
    local defaults={}
    for _,key in ipairs({"before","init","frame","render","beforedel","del","after"}) do
        defaults[key]=function() return "default" end
    end
    local source=table.concat({
        "local state=4",
        "_ct_runs=_ct_runs+1",
        "_editor_class['K']=Class(boss)",
        "_editor_class['K'].cards={boss.move.New(0,0,1)}",
        "_tmp_sc=boss.card.New('Same',1,2,3,4)",
        "function _tmp_sc:init() return 11 end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
        "_tmp_sc=boss.card.New('Same',1,2,3,4)",
        "function _tmp_sc:init() return 22 end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
        "_tmp_sc=boss.card.New('',1,2,3,4)",
        "function _tmp_sc:init() return 33 end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
        "_editor_class['L']=Class(boss)",
        "_editor_class['L'].cards={boss.move.New(0,0,1)}",
        "_tmp_sc=boss.card.New('Other',1,2,3,4)",
        "function _tmp_sc:init() return 44 end",
        "table.insert(_editor_class['L'].cards,_tmp_sc)",
    },"\n")
    local debug_source=table.concat({
        "_editor_class['K']=Class(boss)",
        "local state=4",
        "_ct_runs=_ct_runs+1",
        "_editor_class['K'].cards={}",
        "_tmp_sc=boss.card.New('Debug',1,2,3,4)",
        "function _tmp_sc:init() return 55 end",
        "_editor_class['K'].cards={boss.move.New(0,0,1),_tmp_sc}",
    },"\n")
    local function binding(classes,key,slot,mode)
        local list=classes[key].cards
        local names={}
        for i,card in ipairs(list) do names[i]=type(card.name)=="string" and card.name or "" end
        return {class_key=key,slot=slot,card=list[slot],name=list[slot].name,names=names,
            mode=mode or "practice",include_previous=false}
    end
    local function fixture(debug_mode)
        if environment then environment:Restore() end
        environment=ClassFixture.Install()
        _ct_runs=0;_editor_class={K={},L={}}
        boss.card={New=function(label)
            local card={name=label,is_combat=true}
            for key,fn in next,defaults do card[key]=fn end
            return card
        end}
        boss.move={New=function() return {is_combat=false} end}
        serial=serial+1
        local entry=must(Load.Capture(debug_mode and debug_source or source,
            {name="Target_Boss.lua"}))
        must(entry.reloadable,entry.reason)
        entry.file="Target_Boss.lua"
        local sid="CardTargetSpec:"..serial
        local f=must(Planning.Capture(entry,sid,_editor_class,defaults))
        environment:FinishLoad()
        local capture=f.capture
        local live={capture=capture,snapshot=capture.snapshot,entry=entry,classes=_editor_class,session_id=sid}
        return binding(_editor_class,"K",debug_mode and 2 or 3,debug_mode and "debug" or "practice"),capture,live,f
    end
    local function refusal(value,err,code,label)
        eq(value,nil,label.." refused");eq(type(err),"table",label.." error")
        if type(err)=="table" then
            eq(err.phase,"locate",label.." phase");eq(err.code,code,label.." code")
            eq(err.file,"Target_Boss.lua",label.." file")
            test(type(err.message)=="string",label.." message")
        end
    end
    local function reject(call,code,label)
        local value,err=call();refusal(value,err,code,label)
    end
    local function isolated(overrides)
        local chunk=assert(loadfile(assert(opts.module_path,"module_path required")))
        setfenv(chunk,setmetatable(overrides,{__index=_G}))
        return chunk()
    end
    local ok,problem=pcall(function()
        must(Anchor.Supported(Compose.Capability(debug)))
        eq(Target.Kind,"SpellHotReload.CardTarget","kind");eq(Target.Version,2,"version")
        local b,c,l=fixture()
        local target=must(Target.Resolve(b,c,l))
        eq(target.key,"card:1:K:3","duplicate name selected by actual identity")
        eq(target.card,b.card,"live card");eq(target.slot,3,"live restart slot")
        eq(target.unit,state(c).units[target.key],"actual Card private unit")
        eq(target.card_group,must(Files.Owner(c,Card)),"actual Card group")
        eq(target.capture,c,"common first-load capture")
        eq(target.snapshot,c.snapshot,"version identity");eq(target.base_revision,0,"revision copied")
        eq(target.class,l.classes.K,"class identity");eq(target.list,l.classes.K.cards,"list identity")
        eq(target.names==b.names,false,"names copied");eq(target.mode,"practice","practice mode")
        eq(target.include_previous,false,"restart flag")
        eq(Target.Check(target,b,c,l),true,"immediate recheck")
        local old_target=copy(target);old_target.version=1
        reject(function() return Target.Check(old_target,b,c,l) end,"unsupported","retired target protocol")
        local first=must(Target.Resolve(binding(l.classes,"K",2),c,l))
        eq(first.key,"card:1:K:2","same name other identity is other key")
        b= binding(l.classes,"K",4)
        eq(must(Target.Resolve(b,c,l)).key,"card:1:K:4","unnamed combat")
        b= binding(l.classes,"L",2)
        eq(must(Target.Resolve(b,c,l)).key,"card:1:L:2","other class")
        b,c,l=fixture(true);target=must(Target.Resolve(b,c,l))
        eq(target.key,"card:1:K:2","debug rebuilt list live slot")
        eq(target.mode,"debug","debug mode");eq(target.include_previous,false,"debug restart flag")
        eq(Target.Check(target,b,c,l),true,"debug recheck")
        -- Actual existing binding producer shapes, not a second engine reader.
        b,c,l=fixture()
        local Binding=require("SpellHotReload.Adapters.Card.PracticeBinding")
        lstg={var={sc_index=1}}
        _sc_table={{"K","Same",b.card,3,true}}
        local practice=must(Binding.CaptureCurrent())
        target=must(Target.Resolve(practice,c,l))
        eq(target.slot,3,"real practice producer slot")
        eq(target.include_previous,true,"real practice producer flag")
        _sc_table[1][5]=false
        reject(function() return Target.Check(target,must(Binding.CaptureCurrent()),c,l) end,
            "stale","real producer flag drift")
        b,c,l=fixture(true)
        lstg={var={_boss_class_name="K"},tmpvar={boss={cards=l.classes.K.cards,card_num=2}}}
        _sc_table={};_boss=nil;IsValid=nil
        local debug_binding=must(Binding.CaptureCurrent())
        target=must(Target.Resolve(debug_binding,c,l))
        eq(target.mode,"debug","real debug producer")
        eq(target.slot,2,"real debug identity slot")
        eq(target.include_previous,false,"real debug producer flag")
        -- No constructor/body/compile/debug/cache mutation may be needed.
        b,c,l=fixture()
        local reads=isolated({loadstring=function() error("compile forbidden") end,
            load=function() error("compile forbidden") end,rawset=function() error("write forbidden") end,
            debug=setmetatable({},{__index=function() error("debug forbidden") end}),
            jit={flush=function() error("flush forbidden") end}})
        target=must(reads.Resolve(b,c,l));eq(reads.Check(target,b,c,l),true,"pure reads")
        eq(_ct_runs,1,"only the explicit miniature first load ran")
        eq(l.classes.K.cards[3].init(),22,"old body unchanged")
        -- Structural/refusal matrix across selected/unselected/placeholder owners.
        local cases={
            {"binding slot",function(v) v.slot=0 end,"unsupported"},
            {"fraction",function(v) v.slot=1.5 end,"unsupported"},
            {"mode",function(v) v.mode="stage" end,"unsupported"},
            {"flag",function(v) v.include_previous=1 end,"unsupported"},
            {"debug flag",function(v) v.mode="debug";v.include_previous=true end,"unsupported"},
            {"name type",function(v) v.name={} end,"unsupported"},
            {"sparse names",function(v) v.names[1]=nil end,"unsupported"},
            {"name mismatch",function(v) v.name="else" end,"stale"},
            {"other names",function(v) v.names[2]="else" end,"stale"},
            {"names count",function(v) v.names[5]="" end,"stale"},
            {"card identity",function(v) v.card={} end,"ownership"},
            {"duplicate same name wrong slot",function(v) v.slot=2 end,"ownership"},
            {"placeholder",function(v,_,w) v.slot=1;v.card=w.classes.K.cards[1];v.name=nil end,"ownership"},
            {"unknown class",function(v) v.class_key="missing" end,"ownership"},
            {"released",function(_,_,v) v.released=true end,"stale"},
            {"poisoned",function(_,_,v) v.poisoned=true end,"stale"},
            {"session",function(_,_,v) v.session_id="other" end,"stale"},
            {"capture",function(_,_,v) v.capture={} end,"stale"},
            {"snapshot",function(_,_,v) v.snapshot={} end,"stale"},
            {"entry",function(_,_,v) v.entry=copy(v.entry) end,"stale"},
            {"missing",function(_,_,v) v.entry.missing=true end,"stale"},
            {"reloadable",function(_,_,v) v.entry.reloadable=false end,"stale"},
            {"source",function(_,_,v) v.entry.loaded_source="changed" end,"unsupported"},
            {"anchor",function(_,_,v) v.entry.anchor=function() end end,"unsupported"},
            {"classes",function(_,_,v) v.classes=copy(v.classes) end,"ownership"},
            {"class replace",function(_,_,v) v.classes.K=copy(v.classes.K) end,"ownership"},
            {"list replace",function(_,_,v) v.classes.K.cards=copy(v.classes.K.cards) end,"ownership"},
            {"unselected replace",function(_,_,v) v.classes.K.cards[2]={} end,"ownership"},
            {"other class placeholder",function(_,_,v) v.classes.L.cards[1]={} end,"ownership"},
            {"reorder",function(_,_,v) local a=v.classes.K.cards;a[2],a[3]=a[3],a[2] end,"ownership"},
            {"append",function(_,_,v) v.classes.K.cards[5]={} end,"ownership"},
            {"list extra key",function(_,_,v) v.classes.K.cards.extra={} end,"ownership"},
            {"combat",function(v) v.card.is_combat=false end,"ownership"},
            {"unindexed unit",function(_,v) state(v).units.extra={} end,"ownership"},
        }
        for _,case in ipairs(cases) do
            b,c,l=fixture();local base=c.snapshot
            case[2](b,c,l)
            local value,err=Target.Resolve(b,c,l)
            refusal(value,err,case[3],case[1])
            eq(c.snapshot,base,"no publication on refusal");eq(_ct_runs,1,"no replay on refusal")
        end
        -- Recheck must use freshly captured binding, not a cached UI object.
        local switches={
            {"different current",function(_,_,v) return binding(v.classes,"K",2) end},
            {"mode change",function(v) v.mode="debug";return v end},
            {"restart flag",function(v) v.include_previous=true;return v end},
            {"rename current",function(v) v.card.name="new";v.name="new";v.names[3]="new";return v end},
            {"rename sibling",function(v,_,w) w.classes.K.cards[2].name="new";v.names[2]="new";return v end},
            {"revision in place",function(v,w) w.snapshot.revision=1;return v end},
            {"version installed",function(v,w,x) w.snapshot=copy(w.snapshot);x.snapshot=w.snapshot;return v end},
        }
        for _,case in ipairs(switches) do
            b,c,l=fixture();target=must(Target.Resolve(b,c,l))
            local fresh=case[2](b,c,l)
            local value,err=Target.Check(target,fresh,c,l)
            refusal(value,err,"stale",case[1])
        end
        b,c,l=fixture();b.include_previous=nil
        target=must(Target.Resolve(b,c,l));eq(target.include_previous,false,"nil flag normalized")
        b.include_previous=false;eq(Target.Check(target,b,c,l),true,"nil/false same restart meaning")
        b.include_previous=true;target=must(Target.Resolve(b,c,l))
        eq(target.include_previous,true,"practice previous preserved")
        -- Changing caller's names later cannot rewrite the saved read-set.
        b,c,l=fixture();target=must(Target.Resolve(b,c,l));b.names[2]="changed"
        eq(target.names[2],"Same","saved names independent")
        reject(function() return Target.Check(target,b,c,l) end,"stale","caller name change")
        -- Metatables and thrown objects never trigger hidden handlers/stringify.
        local traps=0
        local hostile=setmetatable({},{__index=function() traps=traps+1;error("index") end,
            __tostring=function() traps=traps+1;error("stringify") end})
        b,c,l=fixture();setmetatable(b,getmetatable(hostile))
        reject(function() return Target.Resolve(b,c,l) end,"unsupported","binding metatable")
        b,c,l=fixture();setmetatable(l.classes.K.cards,getmetatable(hostile))
        reject(function() return Target.Resolve(b,c,l) end,"ownership","list metatable")
        b,c,l=fixture()
        local throwing=isolated({next=function() error(hostile) end})
        reject(function() return throwing.Resolve(b,c,l) end,"stale","opaque primitive failure")
        eq(traps,0,"no hostile handlers")
        -- Tampered target fields are refused, not silently re-resolved.
        for _,field in ipairs({"key","file","session_id","capture","card_group","entry","classes","unit","class_key",
            "card","class","list","snapshot","base_revision","slot","name","mode","include_previous"}) do
            b,c,l=fixture();target=must(Target.Resolve(b,c,l));target[field]="wrong"
            reject(function() return Target.Check(target,b,c,l) end,"stale","target "..field)
        end
        -- Real Current selection and ONE common publication retire the old
        -- target; names never choose between the two identical labels.
        local f
        b,c,l,f=fixture();target=must(Target.Resolve(b,c,l))
        local initial=c.snapshot
        local content=source:gsub("return 22 end","return 222 end")
        local facts=must(Source.Build(content))
        local d=must(Planning.Discover(f,facts,1))
        local function refresh()
            return {capture=c,snapshot=c.snapshot,entry=f.entry,classes=l.classes,session_id=f.session,
                content=content,generation=1,binding=binding(l.classes,"K",3)}
        end
        local prepared,report=Planning.Prepare(f,d,{mode="current",refresh=refresh});must(prepared,report)
        eq(#prepared.dependencies.safe_roots,1,"exact Current root safe")
        eq(#prepared.dependencies.blocked_roots,0,"no hidden blocked root")
        eq(prepared.operation.roots[1].root_id,target.key,"original selected duplicate key")
        local local_piece,card_piece
        for _,record in ipairs(prepared.entries) do
            if record.owner==Card then card_piece=record.fragment end
            if record.owner==Local then local_piece=record.fragment end
        end
        must(local_piece);must(card_piece)
        eq(#local_piece.cell_writes,0,"constant callback does not publish ordinary state")
        eq(#card_piece.raw_writes,1,"one callback really prepared")
        eq(#card_piece.card_plan.keys,1,"one private Card member selected")
        eq(card_piece.card_plan.keys[1],target.key,"exact duplicate selected by identity")
        eq(card_piece.card_plan.publications[1].target,b.card,"write targets original live card")
        eq(Target.Check(target,b,c,l),true,"precommit current recheck")
        eq(c.snapshot,initial,"preparation installs no snapshot")
        local tx=must(Tx.New(f.session));controllers[#controllers+1]=tx
        local receipt,terr=Planning.Publish(f,prepared,tx);must(receipt,terr)
        eq(receipt.changed,true,"genuine changed common receipt")
        eq(receipt.snapshot,c.snapshot,"receipt identifies actual common publication")
        eq(c.snapshot.revision,1,"one common revision")
        eq(b.card.init(),222,"chosen duplicate updated")
        eq(l.classes.K.cards[2].init(),11,"other duplicate untouched")
        eq(_ct_runs,1,"publication never replays miniature source")
        l.snapshot=c.snapshot
        reject(function() return Target.Check(target,b,c,l) end,"stale","old target after publish")
        local new=must(Target.Resolve(b,c,l));eq(new.base_revision,1,"new target uses actual revision")
        eq(new.card_group,must(Files.Owner(c,Card)),"new target owns actual Card group")
        eq(new.unit,state(c).units[new.key],"new target owns actual private version")
        eq(new.card,b.card,"same live card after publication")
        eq(Target.Check(new,b,c,l),true,"new target recheck valid")
    end)
    for _,controller in ipairs(controllers) do eq(controller:Release(),true,"common transaction released") end
    if environment then environment:Restore() end
    for _,key in ipairs({"boss","_editor_class","_tmp_sc","_ct_runs","lstg","_sc_table","_boss","IsValid"}) do rawset(_G,key,saved[key]) end
    if not ok then error(type(problem)=="string" and problem or "CardTargetSpec opaque failure",0) end
    for _,label in ipairs(failures) do print("FAIL CardTargetSpec: "..label) end
    return {passed=passed,failed=failed}
end
return M
