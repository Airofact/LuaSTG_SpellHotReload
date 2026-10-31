local Planning=require("SpellHotReload.tests.PlanningFixture")
-- Real dual-owner preparation and owner/native preflight; never publishes.
local M={}
local serial=0
function M.run()
    local Check=require("SpellHotReload.Apply.CommitCheck")
    local Load=require("SpellHotReload.Load.AnchorLoad")
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local Local=require("SpellHotReload.Adapters.Local.Local")
    local Files=require("SpellHotReload.Pipeline.FileVersions")
    local Source=require("SpellHotReload.Source.FileAnalysis")
    local Compose=require("SpellHotReload.Source.Compose")
    local Anchor=require("SpellHotReload.Load.Anchor")
    local passed,failed,failures=0,0,{}
    local limits={}
    local function test(v,label)
        if v then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end
    end
    local function eq(a,b,label) test(rawequal(a,b),label) end
    local function must(v,e) assert(v,type(e)=="table" and e.message or e);return v,e end
    local function copy(v) local out={};for k,x in next,v do out[k]=x end;return out end
    local keys={"boss","_editor_class","_tmp_sc","_commit_runs"}
    local saved={};for _,key in ipairs(keys) do saved[key]=rawget(_G,key) end
    local old_join,old_set,old_get,old_id=debug.upvaluejoin,debug.setupvalue,debug.getupvalue,debug.upvalueid
    local old_jit=rawget(_G,"jit")
    local joined,written,flushed,traps=0,0,0,0
    local mt={__index=function() traps=traps+1;error("unsafe index") end,
        __len=function() traps=traps+1;error("unsafe length") end,
        __pairs=function() traps=traps+1;error("unsafe pairs") end,
        __eq=function() traps=traps+1;error("unsafe equality") end}
    local names={"before","init","frame","render","beforedel","del","after"}
    local defaults={};for _,name in ipairs(names) do defaults[name]=function() return "default" end end
    local keya,keyb="card:1:K:2","card:1:K:3"
    local source=table.concat({
        "local state=4",
        "local function helper() return state+1 end",
        "local function other() return 100 end",
        "local function setter(v) state=v end",
        "_commit_runs=_commit_runs+1",
        "_editor_class['K'].cards={boss.move.New(0,0,1)}",
        "_tmp_sc=boss.card.New('A',1,2,3,100)",
        "function _tmp_sc:init() return helper() end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
        "_tmp_sc=boss.card.New('B',1,2,3,100)",
        "function _tmp_sc:init() return other() end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
        "_editor_class['L'].cards={}",
        "_tmp_sc=boss.card.New('C',1,2,3,100)",
        "function _tmp_sc:init() return helper()+100 end",
        "table.insert(_editor_class['L'].cards,_tmp_sc)",
    },"\n")
    local candidate=source:gsub("return state%+1","return state+2")
        :gsub("return helper%(%) end","return helper()+3 end")
        :gsub("return other%(%) end","return other()+9 end")
    local function reset()
        debug.upvaluejoin,debug.setupvalue,debug.getupvalue,debug.upvalueid=old_join,old_set,old_get,old_id
        rawset(_G,"jit",old_jit)
    end
    local function forbid()
        debug.upvaluejoin=function() joined=joined+1;error("premature join") end
        debug.setupvalue=function() written=written+1;error("premature write") end
        rawset(_G,"jit",{flush=function() flushed=flushed+1;error("premature flush") end})
    end
    local function fragment(p,owner)
        for _,r in ipairs(p.entries) do if r.owner==owner then return r.fragment end end
        error("missing genuine owner fragment")
    end
    local function fragments(p)
        local out={};for _,r in ipairs(p.entries) do out[#out+1]=r.fragment end;return out
    end
    local function seal(p) return Check.Seal(p.operation,fragments(p)) end
    local function fixture(bytes,roots)
        reset();_commit_runs=0;_editor_class={K={},L={}}
        boss={card={New=function(name)
            local card={name=name,is_combat=true}
            for _,cb in ipairs(names) do card[cb]=defaults[cb] end
            return card
        end},move={New=function() return {is_combat=false} end}}
        local entry=must(Load.Capture(source,{name="Commit_Boss.lua"}))
        must(entry.reloadable,entry.reason);entry.file="Commit_Boss.lua"
        serial=serial+1
        local sid="CommitCheckSpec:"..serial
        local f=must(Planning.Capture(entry,sid,_editor_class,defaults))
        local c=f.capture
        local l={capture=c,snapshot=c.snapshot,entry=entry,session_id=sid,
            classes=_editor_class,content=bytes or candidate,generation=1,fixture=f}
        f.refresh=function() return l end
        local d=must(Planning.Discover(f,must(Source.Build(l.content)),l.generation))
        local p=must(Planning.Prepare(f,d,{mode="file",root_ids=roots or {keya},refresh=f.refresh}))
        eq(#p.dependencies.safe_roots,#(roots or {keya}),"all requested roots genuinely safe")
        eq(#p.dependencies.blocked_roots,0,"no blocked root hides preflight")
        return p,c,l
    end
    local function refusal(v,e,phase,code,label,message)
        eq(v,nil,label.." refused");eq(type(e),"table",label.." structured")
        if type(e)=="table" then
            eq(e.phase,phase,label.." phase");eq(e.code,code,label.." code")
            if message then eq(e.message,message,label.." exact seam")
            else test(type(e.message)=="string",label.." safe message") end
        end
    end
    local function bad(method,change,phase,code,label,message)
        local p,c,l=fixture();local s=must(seal(p))
        forbid();change(s,c,l,p)
        local actual=c.snapshot
        local card=fragment(p,Card).card_view.base.units[keya].card
        local init=rawget(card,"init")
        local v,e=method(s,c,l)
        refusal(v,e,phase,code,label,message)
        eq(c.snapshot,actual,label.." no snapshot write")
        eq(rawget(card,"init"),init,label.." no callback write")
        eq(_commit_runs,1,label.." no source replay")
    end
    local function action(s,kind)
        for _,w in ipairs(s.journal) do if w.kind==kind then return w end end
        error("missing genuine "..kind.." journal action")
    end
    local ok,problem=pcall(function()
        must(Anchor.Supported(Compose.Capability(debug)))
        local p,c,l=fixture();local s=must(seal(p))
        local local_fragment,card_fragment=fragment(p,Local),fragment(p,Card)
        eq(Check.Kind,"SpellHotReload.CommitCheck","kind");eq(Check.Version,2,"neutral preflight version")
        eq(#local_fragment.cell_writes,1,"one actual helper cell write")
        eq(local_fragment.cell_writes[1].name,"helper","exact selected helper")
        eq(#card_fragment.raw_writes,1,"one exact selected callback")
        eq(card_fragment.card_plan.keys[1],keya,"A selected, B unselected")
        eq(#card_fragment.card_plan.keys,1,"only A selected")
        eq(card_fragment.card_runtime.version_view.by_key[keyb].changed,true,"unselected edited B pending")
        eq(Check.Check(s,c,l),true,"fresh complete preflight")
        eq(_commit_runs,1,"single miniature first load")
        local before=c.snapshot
        local init=l.classes.K.cards[2].init
        local helper=must(Anchor.Get(l.entry,"helper"))
        local local_base=must(Files.GetAdapterRecords(c,Local))
        forbid()
        eq(Check.Check(s,c,l),true,"only reads despite mutator traps")
        eq(c.snapshot,before,"no publication");eq(c.snapshot.revision,0,"actual common revision unchanged")
        eq(l.classes.K.cards[2].init,init,"old callback retained")
        eq(Anchor.Get(l.entry,"helper"),helper,"old helper retained")
        eq(Files.GetAdapterRecords(c,Local),local_base,"actual Local group retained")
        -- Mutate through the real old setter, not through the reload plan.
        must(Anchor.Get(l.entry,"setter"))(42)
        eq(Anchor.Get(l.entry,"state"),42,"ordinary scalar evolved")
        eq(Check.Check(s,c,l),true,"evolved scalar is not stale")
        eq(l.classes.K.cards[2]:init(),43,"old callback reads current shared state")
        eq(c.snapshot,before,"evolved scalar has no version publication")
        eq(local_base.state.by_name.helper.definition_version,1,"actual helper version unchanged")
        eq(card_fragment.card_runtime.version_view.by_key[keyb].changed,true,"B still pending after checks")
        eq(_commit_runs,1,"no source or wiring replay")

        -- Exercise common physical checks directly; earlier domain failures must
        -- not stand in for these baseline/shape/permission assertions.
        for _,case in ipairs({
            {"exact bytes",function(s,c,l) l.content=l.content.."\n-- different bytes" end},
            {"missing candidate",function(s,c,l) l.content=nil end},
            {"session changed",function(s,c,l) l.session_id="other" end},
            {"retired capture",function(s,c,l) l.capture={} end},
            {"live snapshot",function(s,c,l) l.snapshot={} end},
            {"entry replaced",function(s,c,l) l.entry={} end},
            {"released",function(s,c,l) l.released=true end},
            {"poisoned",function(s,c,l) l.poisoned=true end},
            {"operation baseline",function(s) s.operation.base_snapshot={} end},
            {"actual snapshot",function(s,c) c.snapshot={} end},
            {"anchor replaced",function(s,c,l) l.entry.anchor=function() end end},
            {"loaded bytes",function(s,c,l) l.entry.loaded_source="other" end},
            {"file changed",function(s,c,l) l.entry.file="Other_Boss.lua" end},
            {"missing file",function(s,c,l) l.entry.missing=true end},
            {"duplicate load",function(s,c,l) l.entry.reloadable=false end},
        }) do
            bad(Check.Mechanical,case[2],"commit","stale",case[1],"file operation baseline changed")
        end
        bad(Check.Owners,function(s) s.fragments[1].base_group={} end,
            "commit","stale","actual Local group identity","Local actual owner/session changed")
        bad(Check.Owners,function(s)
            s.fragments[1].proposed_group.state.by_name.helper.definition_version=99
        end,"commit","ownership","Local proposed definition version","Local proposed definition/version changed")
        for _,case in ipairs({
            {"registry",function(s,c,l) l.classes={} end},
            {"class",function(s,c,l) l.classes.K={} end},
            {"list",function(s,c,l) l.classes.K.cards={} end},
            {"placeholder",function(s,c,l) l.classes.K.cards[1]={} end},
            {"unselected sibling",function(s,c,l) l.classes.K.cards[3]={} end},
            {"other class",function(s,c,l) l.classes.L.cards[1]={} end},
            {"list appended",function(s,c,l) l.classes.K.cards[4]={} end},
            {"list hole",function(s,c,l) l.classes.K.cards[1]=nil end},
            {"extra key",function(s,c,l) l.classes.K.cards.tag={} end},
            {"combat tag",function(s,c,l) l.classes.K.cards[2].is_combat=false end},
        }) do bad(Check.Check,case[2],"locate","ownership","Card ownership "..case[1]) end
        for _,case in ipairs({
            {"selected callback",function(s,c,l) l.classes.K.cards[2].init=function() end end},
            {"unselected callback",function(s,c,l) l.classes.K.cards[3].frame=function() end end},
            {"unselected function",function(s,c,l) old_set(l.entry.anchor,l.entry.slots.other,function() end) end},
            {"selected function",function(s,c,l) old_set(l.entry.anchor,l.entry.slots.helper,function() end) end},
        }) do bad(Check.Check,case[2],"inject","stale",case[1]) end

        bad(Check.Mechanical,function(s) action(s,"cell").before=function() end end,
            "commit","conflict","independent cell preimage","function write authority, position or preimage changed")
        bad(Check.Mechanical,function(s) action(s,"raw").before=function() end end,
            "commit","ownership","independent raw preimage","raw write authority or preimage changed")
        bad(Check.Mechanical,function(s) action(s,"raw").target={} end,
            "commit","ownership","raw target permission","raw write authority or preimage changed")
        for _,case in ipairs({
            {"join index",function(s) s.joins[1].index=999 end},
            {"join missing name",function(s) s.joins[1].index=999;s.joins[1].name=nil end},
        }) do bad(Check.Mechanical,case[2],"commit","ownership",case[1],"join destination is published or invalid") end
        bad(Check.Mechanical,function(s) s.capture_reads[1].donor=999 end,
            "commit","stale","capture donor","published capture slot changed")
        bad(Check.Mechanical,function(s,c,l) l.entry.slots.helper=999 end,
            "commit","stale","anchor slot","function read ownership or value changed")
        bad(Check.Mechanical,function(s) action(s,"raw").value=4 end,
            "commit","ownership","nonfunction raw write","raw write authority or preimage changed")
        bad(Check.Mechanical,function(s) action(s,"cell").value={} end,
            "commit","conflict","nonfunction cell write","function write authority, position or preimage changed")
        bad(Check.Mechanical,function(s)
            table.insert(s.journal,#s.journal,copy(action(s,"cell")))
        end,"commit","conflict","sealed duplicate cell position","function write authority, position or preimage changed")
        -- Identical actions before Seal are deliberately deduplicated.
        p,c,l=fixture();local f=fragment(p,Local)
        f.cell_writes[2]=copy(f.cell_writes[1]);s=must(seal(p));forbid()
        local cell_count=0;for _,w in ipairs(s.journal) do if w.kind=="cell" then cell_count=cell_count+1 end end
        eq(cell_count,1,"identical cell action deduplicated")
        eq(Check.Check(s,c,l),true,"deduplicated genuine plan remains valid")
        local v,e
        for _,case in ipairs({
            {"cell extra key","versions",function(p) fragment(p,Local).cell_writes.extra={} end},
            {"raw extra key","versions",function(p) fragment(p,Card).raw_writes.extra={} end},
            {"join extra key","versions",function(p) fragment(p,Local).joins.extra={} end},
            {"read hole","commit",function(p)
                local reads=fragment(p,Local).read_set;test(#reads>=3,"three real function reads")
                reads[2]=nil
            end},
            {"capture extra key","commit",function(p) fragment(p,Local).capture_reads.extra={} end},
        }) do
            p,c,l=fixture();case[3](p);forbid()
            v,e=seal(p);refusal(v,e,case[2],"ownership","Seal "..case[1])
            eq(c.snapshot,p.operation.base_snapshot,"Seal rejection keeps actual snapshot")
        end
        for _,case in ipairs({
            {"read hole",function(s) s.read_set[2]=nil end},
            {"journal extra key",function(s) s.journal.extra={} end},
            {"join extra key",function(s) s.joins.extra={} end},
            {"capture extra key",function(s) s.capture_reads.extra={} end},
        }) do bad(Check.Mechanical,case[2],"commit","ownership","sealed "..case[1],"dense sealed arrays required") end
        bad(Check.Check,function() debug.upvaluejoin=nil end,"commit","capability","no join")
        bad(Check.Check,function() debug.setupvalue=nil end,"commit","capability","no setter")
        bad(Check.Check,function(s,c,l) setmetatable(l.classes.K.cards,mt) end,
            "locate","ownership","list metatable")
        bad(Check.Mechanical,function(s) setmetatable(s,mt) end,
            "commit","stale","sealed plan metatable","file operation baseline changed")
        p,c,l=fixture();setmetatable(p.operation,mt);forbid()
        v,e=seal(p);refusal(v,e,"commit","ownership","operation metatable","operation and fragments required")
        bad(Check.Check,function(s,c,l)
            local evidence=select(2,Files.GetAdapterRecords(c,Card)).evidence
            setmetatable(evidence.ownership[1].list,mt)
            l.classes.K.cards=setmetatable({},mt)
        end,"locate","ownership","hostile lists never invoke equality")
        eq(traps,0,"no table metamethod invoked")
        local error_object=setmetatable({},{
            __tostring=function() traps=traps+1;error("unsafe error stringify") end,
            __index=function() traps=traps+1;error("unsafe error index") end})
        bad(Check.Check,function() debug.getupvalue=function() error(error_object) end end,
            "commit","internal","owner getter threw opaque object","owner guard threw")
        bad(Check.Mechanical,function() debug.getupvalue=function() error(error_object) end end,
            "commit","internal","native getter threw opaque object","mechanical read failed")
        eq(traps,0,"opaque read error never inspected or stringified")
        p,c,l=fixture();s=must(seal(p));forbid()
        local result,reason
        local thread=coroutine.create(function() result,reason=Check.Check(s,c,l) end)
        test(coroutine.resume(thread),"coroutine returns without throwing")
        refusal(result,reason,"commit","phase","coroutine","commit requires main thread")
        if old_id then
            p,c,l=fixture();s=must(seal(p))
            local read;local old_helper=must(Anchor.Get(l.entry,"helper"))
            for _,r in ipairs(s.capture_reads) do
                if r.fn==old_helper and r.name=="state" then read=r;break end
            end
            must(read,"genuine old helper capture required")
            local name,value=old_get(read.fn,read.index)
            local factory=assert(loadstring("local "..name.."=...;return function() return "..name.." end"))
            local donor=factory(value)
            old_join(read.fn,read.index,donor,1)
            eq(old_get(read.fn,read.index),name,"external rejoin preserves name")
            local _,now=old_get(read.fn,read.index);eq(now,value,"external rejoin preserves value")
            test(old_id(read.fn,read.index)~=old_id(read.anchor,read.donor),"external rejoin changes physical cell")
            forbid();v,e=Check.Mechanical(s,c,l)
            refusal(v,e,"commit","stale","native physical rejoin","published capture was reconnected")
            v,e=Check.Check(s,c,l)
            refusal(v,e,"inject","stale","owner physical rejoin")
        else
            limits[#limits+1]="physical external rejoin needs debug.upvalueid; not exercised"
        end
        p,c,l=fixture();s=must(seal(p));forbid();debug.upvalueid=nil
        eq(Check.Check(s,c,l),true,"id optional; remaining name/slot/value checks pass")
        -- Optional-id acceptance does not prove physical sharing without ids.
        p,c,l=fixture(source,{});s=must(seal(p));forbid()
        eq(s.proposed_snapshot,c.snapshot,"no-op exact actual snapshot")
        eq(#s.journal,0,"no-op zero journal");eq(#s.joins,0,"no-op zero joins")
        eq(Check.Check(s,c,l),true,"empty genuine plan still checked")
        l.classes.K.cards[1]={}
        v,e=Check.Check(s,c,l)
        refusal(v,e,"locate","ownership","no-op checks all placeholder ownership")
        eq(joined,0,"all preflights zero joins")
        eq(written,0,"all preflights zero plan setters")
        eq(flushed,0,"all preflights zero cache flushes")
        eq(traps,0,"all hostile metatables untouched")
    end)
    reset()
    for _,key in ipairs(keys) do rawset(_G,key,saved[key]) end
    if not ok then error(problem,0) end
    for _,label in ipairs(failures) do print("FAIL CommitCheckSpec: "..label) end
    return {passed=passed,failed=failed,limits=limits}
end
return M
