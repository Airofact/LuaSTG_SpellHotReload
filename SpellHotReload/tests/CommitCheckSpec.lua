-- R4 preflight only. Tiny synthetic first loads; never runs the game.
local M = {}
function M.run()
    local Check = require("SpellHotReload.CommitCheck")
    local Load = require("SpellHotReload.Load.AnchorLoad")
    local Capture = require("SpellHotReload.Load.LoadVersions")
    local Cards = require("SpellHotReload.CardVersions")
    local Anchor = require("SpellHotReload.Load.Anchor")
    local passed, failed, failures = 0, 0, {}
    local function test(v, label)
        if v then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end
    end
    local function eq(a,b,label) test(a==b,label) end
    local function must(v,err) assert(v,type(err)=="table" and err.message or err);return v end
    local keys = { "boss", "_editor_class", "_tmp_sc", "_commit_runs" }
    local saved = {}
    for _, key in ipairs(keys) do saved[key]=rawget(_G,key) end
    local old_join, old_set, old_get, old_id = debug.upvaluejoin, debug.setupvalue,
        debug.getupvalue, debug.upvalueid
    local old_jit = rawget(_G,"jit")
    local caps = { getupvalue=true, setupvalue=true, upvaluejoin=true }
    local names = { "before","init","frame","render","beforedel","del","after" }
    local defaults = {}
    for _, name in ipairs(names) do defaults[name]=function() return "default" end end
    local source = table.concat({
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
    local candidate = source:gsub("return state%+1","return state+2")
        :gsub("return helper%(%) end","return helper()+3 end")
        :gsub("return other%(%) end","return other()+9 end")
    local function fixture()
        debug.upvaluejoin=old_join or function() error("presence-only fixture") end
        debug.setupvalue,debug.getupvalue,debug.upvalueid=old_set,old_get,old_id
        _G.jit=old_jit
        _commit_runs=0
        _editor_class={K={},L={}}
        boss={card={New=function(name)
            local card={name=name,is_combat=true}
            for _, cb in ipairs(names) do card[cb]=defaults[cb] end
            return card
        end},move={New=function() return {is_combat=false} end}}
        local entry=must(Load.Capture(source,{capability=caps,name="Commit_Boss.lua"}))
        entry.file="Commit_Boss.lua"
        local capture=must(Capture.Capture(entry,"session",_editor_class,defaults))
        local report=must(Cards.Compare(capture.snapshot,candidate))
        local selection=must(Cards.Select(report,{"card:1:K:2"}))
        local live={capture=capture,snapshot=capture.snapshot,entry=entry,
            session_id="session",classes=_editor_class,content=candidate}
        return selection,capture,live
    end
    local function refusal(selection,capture,live,code,label)
        local value,err=Check.Check(selection,capture,live)
        eq(value,nil,label.." refused")
        eq(type(err),"table",label.." structured")
        if type(err)=="table" then
            eq(err.phase,"commit",label.." phase")
            eq(err.code,code,label.." code")
            test(type(err.message)=="string",label.." safe message")
        end
    end
    local function bad(change,code,label)
        local s,c,l=fixture()
        change(s,c,l)
        refusal(s,c,l,code,label)
    end
    local ok,problem=pcall(function()
        local s,c,l=fixture()
        eq(Check.Kind,"SpellHotReload.CommitCheck","kind")
        eq(Check.Version,1,"version")
        eq(#s.writes,1,"one helper write")
        eq(#s.publications,1,"one current raw callback")
        eq(#s.pending,1,"unselected edited B retained")
        eq(Check.Check(s,c,l),true,"fresh plan")
        eq(_commit_runs,1,"one initialization")
        local joined,written,flushed=0,0,0
        debug.upvaluejoin=function() joined=joined+1;error("premature join") end
        debug.setupvalue=function() written=written+1;error("premature write") end
        _G.jit={flush=function() flushed=flushed+1;error("premature flush") end}
        local before=c.snapshot
        local init=c.classes.K.cards[2].init
        local helper=Anchor.Get(l.entry,"helper")
        eq(Check.Check(s,c,l),true,"check only reads despite mutator traps")
        eq(joined,0,"zero join")
        eq(written,0,"zero write")
        eq(flushed,0,"zero flush")
        eq(c.snapshot,before,"no version install")
        eq(c.classes.K.cards[2].init,init,"no publication")
        eq(Anchor.Get(l.entry,"helper"),helper,"helper retained")
        eq(_commit_runs,1,"no source/wiring replay")
        -- Ordinary state can evolve; identity/ownership reads cannot.
        old_set(l.entry.anchor,l.entry.slots.state,42)
        eq(Check.Check(s,c,l),true,"state setter not a stale definition")
        eq(c.classes.K.cards[2]:init(),43,"old callback still active")
        eq(s.base_revision,0,"no revision advance")
        eq(#s.pending,1,"pending not swallowed")
        bad(function(_,_,v) v.content=v.content.."\n-- different bytes" end,"stale","exact bytes")
        bad(function(_,_,v) v.content=nil end,"stale","missing candidate")
        bad(function(_,_,v) v.session_id="other" end,"stale","session changed")
        bad(function(_,_,v) v.capture={} end,"stale","retired capture")
        bad(function(_,_,v) v.snapshot={} end,"stale","installed snapshot replaced")
        bad(function(_,_,v) v.entry={} end,"stale","entry replaced")
        bad(function(_,_,v) v.released=true end,"stale","released")
        bad(function(_,_,v) v.poisoned=true end,"stale","poisoned")
        bad(function(v) v.base_revision=1 end,"stale","aggregate revision")
        bad(function(v) v.functions.base_revision=1 end,"stale","function revision")
        bad(function(v) v.functions.base={} end,"stale","function base identity")
        bad(function(_,_,v) v.entry.anchor=function() end end,"stale","anchor replaced")
        bad(function(_,_,v) v.entry.loaded_source="other" end,"stale","load bytes changed")
        bad(function(_,_,v) v.entry.file="Other_Boss.lua" end,"stale","file changed")
        bad(function(_,_,v) v.entry.missing=true end,"stale","missing file")
        bad(function(_,_,v) v.entry.reloadable=false end,"stale","duplicate load disabled")
        bad(function(_,_,v) v.classes={} end,"ownership","registry replaced")
        bad(function(_,_,v) v.classes.K={} end,"ownership","class replaced")
        bad(function(_,_,v) v.classes.K.cards={} end,"ownership","list replaced")
        bad(function(_,_,v) v.classes.K.cards[1]={} end,"ownership","placeholder replaced")
        bad(function(_,_,v) v.classes.K.cards[3]={} end,"ownership","unselected sibling replaced")
        bad(function(_,_,v) v.classes.L.cards[1]={} end,"ownership","other class owner replaced")
        bad(function(_,_,v) v.classes.K.cards[4]={} end,"ownership","list appended")
        bad(function(_,_,v) v.classes.K.cards[1]=nil end,"ownership","list hole")
        bad(function(_,_,v) v.classes.K.cards.tag={} end,"ownership","extra array key")
        bad(function(_,_,v) v.classes.K.cards[2].is_combat=false end,"ownership","combat tag changed")
        bad(function(_,_,v) v.classes.K.cards[2].init=function() end end,"stale","current callback replaced")
        bad(function(_,_,v) v.classes.K.cards[3].frame=function() end end,"stale","unselected callback replaced")
        bad(function(_,_,v) old_set(v.entry.anchor,v.entry.slots.other,function() end) end,"stale","unselected function replaced")
        bad(function(_,_,v) old_set(v.entry.anchor,v.entry.slots.helper,function() end) end,"stale","write function replaced")
        bad(function(v) v.writes[1].before=function() end end,"stale","write preimage independent")
        bad(function(v) v.publications[1].before=function() end end,"stale","publish preimage independent")
        bad(function(v) v.publications[1].target={} end,"stale","publication owner")
        bad(function(v) v.publications[2]=v.publications[1] end,"ownership","duplicate publication")
        bad(function(v) v.writes[2]=v.writes[1] end,"stale","duplicate write")
        bad(function(v) v.joins[1].index=999 end,"stale","candidate index drift")
        bad(function(v) v.joins[1].index=999;v.joins[1].name=nil end,"stale","missing candidate name")
        bad(function(v) v.capture_reads[1].donor=999 end,"stale","saved donor drift")
        bad(function(v) v.entry.slots.helper=999 end,"stale","anchor index drift")
        bad(function(v) v.read_set[2]=nil end,"unsupported","read array hole")
        bad(function(v) v.writes.extra={} end,"unsupported","extra plan key")
        bad(function(v) v.publications[1].value=4 end,"unsupported","nonfunction publication")
        bad(function(v) v.writes[1].value={} end,"unsupported","nonfunction write")
        bad(function() debug.upvaluejoin=nil end,"capability","no join refusal")
        bad(function() debug.setupvalue=nil end,"capability","no setter refusal")
        local trap=0
        bad(function(_,_,v)
            setmetatable(v.classes.K.cards,{__index=function() trap=trap+1;error("index") end,
                __len=function() trap=trap+1;error("length") end,
                __pairs=function() trap=trap+1;error("pairs") end})
        end,"ownership","list metatable")
        bad(function(v) setmetatable(v,{__index=function() trap=trap+1;error("plan index") end}) end,
            "unsupported","plan metatable")
        bad(function(_,c,v)
            local mt={__eq=function() trap=trap+1;return true end}
            setmetatable(c.ownership[1].list,mt)
            v.classes.K.cards=setmetatable({},mt)
        end,"ownership","raw list identity never invokes equality")
        eq(trap,0,"no table metamethod invoked")
        s,c,l=fixture()
        local error_object=setmetatable({},{
            __tostring=function() trap=trap+1;error("error stringify") end,
            __index=function() trap=trap+1;error("error index") end})
        debug.getupvalue=function() error(error_object) end
        refusal(s,c,l,"stale","getter threw unsafe object")
        eq(trap,0,"unknown read error has no metamethod calls")
        s,c,l=fixture()
        local result,reason
        local thread=coroutine.create(function() result,reason=Check.Check(s,c,l) end)
        test(coroutine.resume(thread),"coroutine returns refusal not error")
        eq(result,nil,"coroutine refused")
        eq(type(reason)=="table" and reason.code or nil,"unsupported","coroutine reason")
        if old_join and old_id then
            s,c,l=fixture()
            local read=s.capture_reads[1]
            local name,value=old_get(read.fn,read.index)
            local factory=assert(loadstring("local "..name.."=...;return function() return "..name.." end"))
            local donor=factory(value)
            old_join(read.fn,read.index,donor,1)
            eq(old_get(read.fn,read.index),name,"rejoin preserved name")
            local _,now=old_get(read.fn,read.index)
            eq(now,value,"rejoin preserved value")
            refusal(s,c,l,"stale","physical external rejoin")
        else
            test(true,"physical rejoin not available: Lua5.1 does not prove sharing")
        end
        s,c,l=fixture()
        debug.upvalueid=nil
        eq(Check.Check(s,c,l),true,"id optional; name/value checks still apply")
        s,c,l=fixture()
        local unchanged=must(Cards.Compare(c.snapshot,source))
        local empty=must(Cards.Select(unchanged,{}))
        l.content=source
        eq(Check.Check(empty,c,l),true,"empty no-op still checked")
        l.classes.K.cards[1]={}
        refusal(empty,c,l,"ownership","empty plan still checks all ownership")
    end)
    debug.upvaluejoin,debug.setupvalue,debug.getupvalue,debug.upvalueid=old_join,old_set,old_get,old_id
    _G.jit=old_jit
    for _, key in ipairs(keys) do rawset(_G,key,saved[key]) end
    if not ok then error(problem) end
    for _, label in ipairs(failures) do print("FAIL CommitCheckSpec: "..label) end
    return {passed=passed,failed=failed}
end
return M
