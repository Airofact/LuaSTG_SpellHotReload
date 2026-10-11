-- Synthetic first-load ownership only; never game/generated source.
-- Presence-only join fixture on Lua5.1 permits metadata, not shared-cell proof.
local M={}
local serial=0
function M.run(opts)
    opts=opts or {}
    local Target=opts.target or require("SpellHotReload.CardTarget")
    local Load=require("SpellHotReload.Load.AnchorLoad")
    local Versions=require("SpellHotReload.Load.LoadVersions")
    local Cards=require("SpellHotReload.CardVersions")
    local Tx=require("SpellHotReload.CardCommit")
    local passed,failed,failures=0,0,{}
    local function test(value,label)
        if value then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end
    end
    local function eq(a,b,label) test(rawequal(a,b),label) end
    local function must(value,err) assert(value,type(err)=="table" and err.message or err);return value end
    local function copy(value) local out={} for k,v in next,value do out[k]=v end return out end
    local saved={}
    for _,key in ipairs({"boss","_editor_class","_tmp_sc","_ct_runs","lstg","_sc_table","_boss","IsValid"}) do saved[key]=rawget(_G,key) end
    local join=debug.upvaluejoin
    if not join then debug.upvaluejoin=function() error("presence only") end end
    local defaults={}
    for _,key in ipairs({"before","init","frame","render","beforedel","del","after"}) do
        defaults[key]=function() return "default" end
    end
    local source=table.concat({
        "local state=4",
        "_ct_runs=_ct_runs+1",
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
        "_editor_class['L'].cards={boss.move.New(0,0,1)}",
        "_tmp_sc=boss.card.New('Other',1,2,3,4)",
        "function _tmp_sc:init() return 44 end",
        "table.insert(_editor_class['L'].cards,_tmp_sc)",
    },"\n")
    local debug_source=table.concat({
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
        _ct_runs=0;_editor_class={K={},L={}}
        boss={card={New=function(label)
            local card={name=label,is_combat=true}
            for key,fn in next,defaults do card[key]=fn end
            return card
        end},move={New=function() return {is_combat=false} end}}
        serial=serial+1
        local entry=must(Load.Capture(debug_mode and debug_source or source,
            {name="Target_Boss.lua",capability={getupvalue=true,setupvalue=true,upvaluejoin=true}}))
        entry.file="Target_Boss.lua"
        local sid="CardTargetSpec:"..serial
        local capture=must(Versions.Capture(entry,sid,_editor_class,defaults))
        local live={capture=capture,snapshot=capture.snapshot,entry=entry,classes=_editor_class,session_id=sid}
        return binding(_editor_class,"K",debug_mode and 2 or 3,debug_mode and "debug" or "practice"),capture,live
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
        eq(Target.Kind,"SpellHotReload.CardTarget","kind");eq(Target.Version,1,"version")
        local b,c,l=fixture()
        local target=must(Target.Resolve(b,c,l))
        eq(target.key,"card:1:K:3","duplicate name selected by actual identity")
        eq(target.card,b.card,"live card");eq(target.slot,3,"live restart slot")
        eq(target.unit,c.snapshot.units[target.key],"published unit")
        eq(target.snapshot,c.snapshot,"version identity");eq(target.base_revision,0,"revision copied")
        eq(target.class,l.classes.K,"class identity");eq(target.list,l.classes.K.cards,"list identity")
        eq(target.names==b.names,false,"names copied");eq(target.mode,"practice","practice mode")
        eq(target.include_previous,false,"restart flag")
        eq(Target.Check(target,b,c,l),true,"immediate recheck")
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
        local Binding=require("SpellHotReload.PracticeBinding")
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
        eq(_ct_runs,1,"initialization once")
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
            {"source",function(_,_,v) v.entry.loaded_source="changed" end,"stale"},
            {"anchor",function(_,_,v) v.entry.anchor=function() end end,"stale"},
            {"classes",function(_,_,v) v.classes=copy(v.classes) end,"ownership"},
            {"class replace",function(_,_,v) v.classes.K=copy(v.classes.K) end,"ownership"},
            {"list replace",function(_,_,v) v.classes.K.cards=copy(v.classes.K.cards) end,"ownership"},
            {"unselected replace",function(_,_,v) v.classes.K.cards[2]={} end,"ownership"},
            {"other class placeholder",function(_,_,v) v.classes.L.cards[1]={} end,"ownership"},
            {"reorder",function(_,_,v) local a=v.classes.K.cards;a[2],a[3]=a[3],a[2] end,"ownership"},
            {"append",function(_,_,v) v.classes.K.cards[5]={} end,"ownership"},
            {"list extra key",function(_,_,v) v.classes.K.cards.extra={} end,"ownership"},
            {"combat",function(v) v.card.is_combat=false end,"ownership"},
            {"unindexed unit",function(_,v) v.snapshot.units.extra={} end,"ownership"},
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
        for _,field in ipairs({"key","file","session_id","card","class","list","snapshot","base_revision","mode"}) do
            b,c,l=fixture();target=must(Target.Resolve(b,c,l));target[field]="wrong"
            reject(function() return Target.Check(target,b,c,l) end,"stale","target "..field)
        end
        -- Consumers still enforce candidate fixed layout; no unsafe remap here.
        b,c,l=fixture()
        local diff,err=Cards.Compare(c.snapshot,source:gsub("'Same'","'Renamed'"))
        eq(diff,nil,"candidate rename remains refused");eq(err.code,"ambiguous","fixed layout refusal")
        -- Integration: select exact captured root, commit, then retire old target.
        b,c,l=fixture();target=must(Target.Resolve(b,c,l))
        local content=source:gsub("return 22 end","return 222 end")
        local report=must(Cards.Compare(c.snapshot,content))
        local selection=must(Cards.Select(report,{target.key}))
        eq(Target.Check(target,b,c,l),true,"precommit current recheck")
        l.content=content
        local tx=must(Tx.New(l.session_id))
        local ran,receipt,terr=tx:Run(function(token) return tx:Commit(token,selection,c,l) end)
        eq(ran,true,"transaction scope");must(receipt,terr)
        eq(b.card.init(),222,"chosen duplicate updated")
        eq(l.classes.K.cards[2].init(),11,"other duplicate untouched")
        eq(_ct_runs,1,"integration no initialization replay")
        l.snapshot=c.snapshot
        reject(function() return Target.Check(target,b,c,l) end,"stale","old target after publish")
        local new=must(Target.Resolve(b,c,l));eq(new.base_revision,1,"new target uses published revision")
        eq(tx:Release(),true,"transaction released")
    end)
    debug.upvaluejoin=join
    for _,key in ipairs({"boss","_editor_class","_tmp_sc","_ct_runs","lstg","_sc_table","_boss","IsValid"}) do rawset(_G,key,saved[key]) end
    if not ok then error(problem) end
    for _,label in ipairs(failures) do print("FAIL CardTargetSpec: "..label) end
    return {passed=passed,failed=failed}
end
return M
