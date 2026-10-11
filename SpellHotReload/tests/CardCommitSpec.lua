-- Synthetic first loads and fault injection, never engine/game chunks.
-- Lua5.1 raw/cell-only cases use a presence-only join fixture (never invoked);
-- real new-closure sharing and hot-JIT cases require actual LuaJIT APIs.
local M = {}
local serial=0
function M.run(opts)
    opts = opts or {}
    local Tx = opts.transaction or require("SpellHotReload.CardCommit")
    local Load = require("SpellHotReload.Load.AnchorLoad")
    local Capture = require("SpellHotReload.Load.LoadVersions")
    local Cards = require("SpellHotReload.CardVersions")
    local Anchor = require("SpellHotReload.Load.Anchor")
    local passed, failed, failures = 0, 0, {}
    local function test(v, label)
        if v then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end
    end
    local function eq(a,b,label) test(rawequal(a,b),label) end
    local function must(v,err) assert(v,type(err)=="table" and err.message or err);return v end
    local globals={"boss","_editor_class","_tmp_sc","_tx_runs"}
    local saved={}
    for _,key in ipairs(globals) do saved[key]=rawget(_G,key) end
    local get,set,join,id=debug.getupvalue,debug.setupvalue,debug.upvaluejoin,debug.upvalueid
    local real_jit=rawget(_G,"jit")
    local names={"before","init","frame","render","beforedel","del","after"}
    local defaults={}
    for _,name in ipairs(names) do defaults[name]=function() return "default" end end
    local source=table.concat({
        "local state=4",
        "local flag=false",
        "local empty=nil",
        "local function helper() return state+1 end",
        "local function other() return 100 end",
        "local function setter(v) state=v end",
        "_tx_runs=_tx_runs+1",
        "_editor_class['K'].cards={boss.move.New(0,0,1)}",
        "_tmp_sc=boss.card.New('A',1,2,3,100)",
        "function _tmp_sc:init() return helper() end",
        "function _tmp_sc:frame() return 10 end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
        "_tmp_sc=boss.card.New('B',1,2,3,100)",
        "function _tmp_sc:init() return other() end",
        "function _tmp_sc:frame() return 10 end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
        "_editor_class['L'].cards={}",
        "_tmp_sc=boss.card.New('C',1,2,3,100)",
        "function _tmp_sc:init() return helper()+100 end",
        "table.insert(_editor_class['L'].cards,_tmp_sc)",
    },"\n")
    local full=source:gsub("return state%+1","return state+2")
        :gsub("return 100 end","return 200 end")
        :gsub("return helper%(%) end","return helper()+3,flag,empty end")
        :gsub("return other%(%) end","return other()+9 end")
        :gsub("return 10 end","return 20 end")
    local function reset()
        debug.getupvalue,debug.setupvalue,debug.upvaluejoin,debug.upvalueid=get,set,join,id
        rawset(_G,"jit",real_jit)
    end
    local function fixture(kind, module)
        reset()
        -- Only permits planning, never used to prove a successful join.
        if not join then debug.upvaluejoin=function() error("presence only, no sharing") end end
        _tx_runs=0;_editor_class={K={},L={}}
        boss={card={New=function(name)
            local card={name=name,is_combat=true}
            for _,cb in ipairs(names) do card[cb]=defaults[cb] end
            return card
        end},move={New=function() return {is_combat=false} end}}
        serial=serial+1
        local sid="CardCommitSpec:"..tostring(serial)
        local entry=must(Load.Capture(source,{name="Tx_Boss.lua",
            capability={getupvalue=true,setupvalue=true,upvaluejoin=true}}))
        entry.file="Tx_Boss.lua"
        local capture=must(Capture.Capture(entry,sid,_editor_class,defaults))
        local content=kind=="raw" and source:gsub("return 10 end","return 20 end")
            or (kind=="cell" and source:gsub("return 100 end","return 200 end") or full)
        local report=must(Cards.Compare(capture.snapshot,content))
        local keys=kind=="cell" and {"card:1:K:3"} or {"card:1:K:2","card:1:K:3"}
        local selection=must(Cards.Select(report,keys))
        local live={capture=capture,snapshot=capture.snapshot,entry=entry,session_id=sid,
            classes=_editor_class,content=content}
        local tx=must((module or Tx).New(sid))
        return tx,selection,capture,live
    end
    local function scoped(tx,s,c,l)
        local ran,value,err=tx:Run(function(token) return tx:Commit(token,s,c,l) end)
        test(ran==true,"scope completed")
        return value,err
    end
    local function refusal(v,err,code,label)
        eq(v,nil,label.." refused")
        eq(type(err),"table",label.." structural error")
        if type(err)=="table" then
            eq(err.phase,"commit",label.." phase")
            eq(err.code,code,label.." code")
            test(type(err.message)=="string",label.." message")
            eq(err.file,"Tx_Boss.lua",label.." file")
        end
    end
    local function baseline(s,c,l)
        local result={snapshot=c.snapshot,anchor=l.entry.anchor,source=l.entry.loaded_source,
            runs=_tx_runs,writes={},pubs={}}
        for i,op in ipairs(s.writes) do result.writes[i]=select(2,get(op.anchor,op.index)) end
        for i,op in ipairs(s.publications) do result.pubs[i]=rawget(op.target,op.key) end
        return result
    end
    local function unchanged(s,c,l,b,label)
        eq(c.snapshot,b.snapshot,label.." snapshot")
        eq(l.entry.anchor,b.anchor,label.." anchor")
        eq(l.entry.loaded_source,b.source,label.." load source")
        eq(_tx_runs,b.runs,label.." no initialization")
        for i,op in ipairs(s.writes) do
            eq(select(2,get(op.anchor,op.index)),b.writes[i],label.." cell "..i)
        end
        for i,op in ipairs(s.publications) do
            eq(rawget(op.target,op.key),b.pubs[i],label.." callback "..i)
        end
    end
    local function isolated(overrides)
        local chunk=assert(loadfile(assert(opts.module_path,"isolated module path required")))
        setfenv(chunk,setmetatable(overrides or {},{__index=_G}))
        return chunk()
    end
    local ok,problem=pcall(function()
        eq(Tx.Kind,"SpellHotReload.CardCommit","kind")
        eq(Tx.Version,1,"version")
        for _,sid in ipairs({"",false,4,{}}) do
            local v,err=Tx.New(sid)
            eq(v,nil,"invalid session");eq(type(err),"table","invalid session error")
        end
        -- Raw-only publication works without relying on a fake shared join.
        local tx,s,c,l=fixture("raw")
        local b=baseline(s,c,l)
        eq(#s.joins,0,"raw-only zero joins");eq(#s.writes,0,"raw-only zero cells")
        local flushes=0
        rawset(_G,"jit",{flush=function(...) flushes=flushes+1;eq(select("#",...),0,"whole cache") end})
        local receipt=must(scoped(tx,s,c,l))
        eq(receipt.kind,"SpellHotReload.CardCommit.Receipt","receipt kind")
        eq(receipt.snapshot,c.snapshot,"installed snapshot returned")
        eq(receipt.changed,true,"publication changed")
        eq(c.snapshot.revision,1,"revision after whole group")
        eq(flushes,1,"one flush for transaction")
        eq(l.entry.anchor,b.anchor,"unique anchor retained")
        eq(l.entry.loaded_source,source,"load baseline retained")
        eq(_tx_runs,1,"normal initialization once")
        for _,op in ipairs(s.publications) do eq(rawget(op.target,op.key),op.value,"all raw callbacks installed") end
        eq(l.classes.K.cards[2]:frame(),20,"A next call")
        eq(l.classes.K.cards[3]:frame(),20,"B next call")
        test(#Cards.Compare(c.snapshot,l.content).changed==0,"published definitions compare clean")

        tx,s,c,l=fixture("cell")
        eq(#s.joins,0,"constant function needs no new joins")
        eq(#s.writes,1,"one genuine shared function cell")
        local old_callback=l.classes.K.cards[3].init
        receipt=must(scoped(tx,s,c,l))
        eq(receipt.snapshot.functions.revision,1,"function revision installed")
        eq(old_callback(),200,"original callback sees replaced anchor cell")
        eq(l.classes.K.cards[3].init,old_callback,"helper-only keeps wrapper identity")
        -- Optional callback deletion publishes its captured genuine default.
        tx,s,c,l=fixture("raw")
        l.content=source:gsub("function _tmp_sc:frame%(%) return 10 end","")
        s=must(Cards.Select(must(Cards.Compare(c.snapshot,l.content)),{"card:1:K:2"}))
        receipt=must(scoped(tx,s,c,l))
        eq(l.classes.K.cards[2].frame,defaults.frame,"deleted optional default restored")
        eq(c.snapshot.units["card:1:K:2"].callbacks.frame.body,nil,"deleted version body")
        test(#Cards.Compare(c.snapshot,l.content).changed>0,"unselected deletion pending")
        -- Bodies are not run by commit, even bodies which immediately throw.
        tx,s,c,l=fixture("raw")
        l.content=source:gsub("return 10 end","error('body must not run') end")
        s=must(Cards.Select(must(Cards.Compare(c.snapshot,l.content)),{"card:1:K:2"}))
        must(scoped(tx,s,c,l))
        eq(_tx_runs,1,"throwing candidate body not executed by commit")
        -- No-op validates ownership/scope, consumes once but never flushes.
        tx,s,c,l=fixture("raw")
        s=must(Cards.Select(must(Cards.Compare(c.snapshot,source)),{}));l.content=source
        flushes=0;rawset(_G,"jit",{flush=function() flushes=flushes+1 end})
        local duplicate
        local ran=tx:Run(function(token)
            receipt=must(tx:Commit(token,s,c,l))
            local v,err=tx:Commit(token,s,c,l);duplicate=err;eq(v,nil,"token once")
        end)
        eq(ran,true,"no-op scope");eq(receipt.changed,false,"no-op receipt")
        eq(receipt.snapshot,s.base,"no-op baseline identity");eq(flushes,0,"no-op cache untouched")
        eq(duplicate.code,"stale","consumed token refusal")
        -- Invalid scope/session, stale bytes, missing, owner/revision failures.
        local changes={
            {"bytes",function(_,_,v) v.content=v.content.." " end,"stale"},
            {"session",function(_,_,v) v.session_id="other" end,"stale"},
            {"capture",function(_,_,v) v.capture={} end,"stale"},
            {"revision",function(v) v.base_revision=99 end,"stale"},
            {"missing",function(_,_,v) v.entry.missing=true end,"stale"},
            {"owner",function(_,_,v) v.classes.K.cards[1]={} end,"ownership"},
            {"live callback",function(_,_,v) v.classes.K.cards[3].init=function() end end,"stale"},
            {"no API",function() debug.upvaluejoin=nil end,"capability"},
        }
        for _,case in ipairs(changes) do
            tx,s,c,l=fixture("raw");b=baseline(s,c,l)
            case[2](s,c,l);local v,err=scoped(tx,s,c,l)
            refusal(v,err,case[3],case[1]);unchanged(s,c,l,b,case[1])
        end
        tx,s,c,l=fixture("raw");b=baseline(s,c,l)
        local v,err=tx:Commit({},s,c,l)
        refusal(v,err,"stale","outside scope")
        unchanged(s,c,l,b,"outside")
        local result
        tx:Run(function(token) result=token end)
        v,err=tx:Commit(result,s,c,l);refusal(v,err,"stale","expired scope")
        local tx2=must(Tx.New(l.session_id))
        tx:Run(function(token)
            local a,e=tx2:Commit(token,s,c,l);refusal(a,e,"stale","foreign controller")
        end)
        -- Recheck cache callbacks that alter live state; no write may follow.
        tx,s,c,l=fixture("raw");b=baseline(s,c,l)
        rawset(_G,"jit",{flush=function() l.content=l.content.."changed" end})
        v,err=scoped(tx,s,c,l);refusal(v,err,"stale","flush changes bytes")
        unchanged(s,c,l,b,"flush stale")
        tx,s,c,l=fixture("raw");b=baseline(s,c,l)
        rawset(_G,"jit",{flush=function() debug.setupvalue=function() end end})
        v,err=scoped(tx,s,c,l);refusal(v,err,"capability","flush changes API")
        unchanged(s,c,l,b,"API stale")
        local traps=0
        local hostile=setmetatable({},{__tostring=function() traps=traps+1;error("stringify") end,
            __index=function() traps=traps+1;error("index") end})
        tx,s,c,l=fixture("raw");b=baseline(s,c,l)
        rawset(_G,"jit",{flush=function() error(hostile) end})
        v,err=scoped(tx,s,c,l);refusal(v,err,"capability","hostile flush")
        eq(traps,0,"error object never touched");unchanged(s,c,l,b,"cache failure")
        -- Reverse journal for raw publication/version, including mutate-then-throw.
        for _,after in ipairs({false,true}) do
            for cut=1,3 do
                local writes,restore_order,trigger=0,{},false
                local isolated_tx=isolated({rawset=function(target,key,value)
                    writes=writes+1
                    if trigger then restore_order[#restore_order+1]=key end
                    if writes==cut then
                        trigger=true
                        if after then rawset(target,key,value) end
                        error(hostile)
                    end
                    return rawset(target,key,value)
                end})
                tx,s,c,l=fixture("raw",isolated_tx);b=baseline(s,c,l)
                v,err=scoped(tx,s,c,l)
                refusal(v,err,"publish","raw cut "..cut)
                unchanged(s,c,l,b,"raw rollback")
                eq(tx:Poisoned(),false,"successful rollback not poison")
                eq(#restore_order,cut,"attempted operation included")
                eq(restore_order[1],cut==3 and "snapshot" or "frame","reverse begins at failed raw op")
                eq(traps,0,"hostile raw error not touched")
            end
        end
        -- A raw write that returns without mutation is also failure.
        local no_write=isolated({rawset=function() end})
        tx,s,c,l=fixture("raw",no_write);b=baseline(s,c,l)
        v,err=scoped(tx,s,c,l);refusal(v,err,"publish","raw postimage")
        unchanged(s,c,l,b,"no raw write")
        -- Restoring missing raw keys uses nil, not a default/inherited value.
        tx,s,c,l=fixture("raw")
        local card=l.classes.K.cards[2]
        card.frame=nil;s.publications[1].before=nil
        for _,read in ipairs(s.read_set) do if read.target==card and read.key=="frame" then read.value=nil end end
        local count=0
        local remove_restore=isolated({rawset=function(t,k,value)
            count=count+1
            if count==2 then error("raw fault") end
            return rawset(t,k,value)
        end})
        tx=must(remove_restore.New(l.session_id));b=baseline(s,c,l)
        v,err=scoped(tx,s,c,l);refusal(v,err,"publish","missing-key rollback")
        eq(rawget(card,"frame"),nil,"missing raw key restored")
        unchanged(s,c,l,b,"nil rollback")
        -- Cell setter before/after-write throw and incorrect name/postimage.
        for _,how in ipairs({"before","after","wrong-name","no-write"}) do
            tx,s,c,l=fixture("cell");b=baseline(s,c,l)
            local calls=0
            debug.setupvalue=function(fn,index,value)
                calls=calls+1
                if calls==1 then
                    if how=="before" then error(hostile) end
                    if how=="after" then set(fn,index,value);error(hostile) end
                    if how=="wrong-name" then set(fn,index,value);return "wrong" end
                    return get(fn,index)
                end
                return set(fn,index,value)
            end
            v,err=scoped(tx,s,c,l);refusal(v,err,"publish","cell "..how)
            unchanged(s,c,l,b,"cell rollback")
            eq(tx:Poisoned(),false,"cell restored not poison")
        end
        -- Rollback failure poisons same-id peer and recreation, no reset via Release.
        local poison_tx=isolated({rawset=function(t,k,value)
            if type(value)=="function" and k=="frame" then rawset(t,k,value) end
            error(hostile)
        end})
        tx,s,c,l=fixture("raw",poison_tx)
        local peer=must(poison_tx.New(l.session_id))
        v,err=scoped(tx,s,c,l);refusal(v,err,"rollback","poison raw")
        eq(tx:Poisoned(),true,"poison flag");eq(peer:Poisoned(),true,"session peer poisoned")
        v,err=peer:Run(function() error("must not run") end)
        eq(v,nil,"poison blocks Run");eq(err.code,"poisoned","peer poison code")
        v,err=poison_tx.New(l.session_id);eq(v,nil,"same session recreation refused");eq(err.code,"poisoned","new poison code")
        eq(tx:Release(),true,"poison release");eq(tx:Release(),true,"idempotent release")
        eq(tx:Poisoned(),true,"release does not clear poison")
        test(poison_tx.New(l.session_id..":new")~=nil,"different session can start")
        -- Cell recovery failure also poisons, even when raw writes never began.
        tx,s,c,l=fixture("cell")
        local cell_attempts=0
        debug.setupvalue=function(fn,index,value)
            cell_attempts=cell_attempts+1
            if cell_attempts==1 then set(fn,index,value) end
            error(hostile)
        end
        v,err=scoped(tx,s,c,l);refusal(v,err,"rollback","poison cell")
        eq(tx:Poisoned(),true,"failed cell rollback poisons")
        eq(cell_attempts,2,"failed cell restore attempted")
        -- Preparation errors do not consume or mutate; unsafe objects stay opaque.
        local failing_next=isolated({require=function(name)
            if name=="SpellHotReload.Card" then
                return setmetatable({ProposeVersion=function() error(hostile) end},
                    {__index=require(name)})
            end
            return require(name)
        end})
        tx,s,c,l=fixture("raw",failing_next);b=baseline(s,c,l)
        v,err=scoped(tx,s,c,l);refusal(v,err,"unsupported","metadata throw")
        unchanged(s,c,l,b,"failed preparation")
        eq(tx:Poisoned(),false,"preparation does not poison")
        -- Invalidation cannot rewrite the sealed action records via caller arrays.
        tx,s,c,l=fixture("raw")
        local original_value=s.publications[1].value
        rawset(_G,"jit",{flush=function() s.publications[1].value=function() return 999 end end})
        receipt=must(scoped(tx,s,c,l))
        eq(rawget(s.publications[1].target,s.publications[1].key),original_value,"sealed actions used")
        -- Table/plan metatables refuse before any cache/mutation side effect.
        tx,s,c,l=fixture("raw");b=baseline(s,c,l)
        setmetatable(s,{__index=function() traps=traps+1;error(hostile) end})
        v,err=scoped(tx,s,c,l);refusal(v,err,"unsupported","plan metatable")
        unchanged(s,c,l,b,"unsafe plan")
        tx,s,c,l=fixture("raw");b=baseline(s,c,l)
        setmetatable(l.classes.K.cards[2],{__newindex=function() traps=traps+1;error(hostile) end})
        v,err=scoped(tx,s,c,l);refusal(v,err,"ownership","target metatable")
        unchanged(s,c,l,b,"unsafe target")
        -- Reentrancy during trusted test primitives is refused, even at teardown.
        local reentered,released
        local reentry_tx=isolated({rawset=function(t,k,value)
            if tx then
                local a,e=tx:Commit({},s,c,l);reentered=e;eq(a,nil,"nested commit blocked")
                local b2,e2=tx:Release();released=e2;eq(b2,nil,"midcommit Release blocked")
            end
            return rawset(t,k,value)
        end})
        tx,s,c,l=fixture("raw",reentry_tx)
        must(scoped(tx,s,c,l))
        eq(reentered.code,"phase","nested error");eq(released.code,"phase","release error")
        -- Coroutine and release scope constraints stay enforced.
        tx,s,c,l=fixture("raw")
        tx:Run(function(token)
            local thread=coroutine.create(function()
                local a,e=tx:Commit(token,s,c,l);refusal(a,e,"phase","coroutine commit")
            end)
            eq(coroutine.resume(thread),true,"coroutine refusal returns")
        end)
        eq(tx:Release(),true,"release success")
        v,err=tx:Run(function() end);eq(v,nil,"released Run");eq(err.code,"stale","released code")
        if join and id then
            -- Full mixed journal: fail EVERY cell/raw/version operation, before
            -- and after mutation. All old values restored in exact reverse order.
            for _,after in ipairs({false,true}) do
                for cut=1,7 do
                    local count,trigger,order=0,false,{}
                    local function perform(fn,key,value,write)
                        count=count+1
                        if trigger then order[#order+1]={fn,key,value} end
                        if count==cut then
                            trigger=true
                            if after then write() end
                            error(hostile)
                        end
                        return write()
                    end
                    local mixed=isolated({rawset=function(t,k,value)
                        return perform(t,k,value,function() return rawset(t,k,value) end)
                    end})
                    tx,s,c,l=fixture("full",mixed);b=baseline(s,c,l)
                    eq(#s.writes+#s.publications+1,7,"mixed journal length")
                    debug.setupvalue=function(fn,index,value)
                        return perform(fn,index,value,function() return set(fn,index,value) end)
                    end
                    v,err=scoped(tx,s,c,l);refusal(v,err,"publish","mixed cut "..cut)
                    unchanged(s,c,l,b,"mixed rollback")
                    eq(tx:Poisoned(),false,"mixed restored")
                    eq(#order,cut,"all attempted operations restored")
                    local expected={}
                    for _,op in ipairs(s.writes) do expected[#expected+1]={op.anchor,op.index,op.before} end
                    for _,op in ipairs(s.publications) do expected[#expected+1]={op.target,op.key,op.before} end
                    expected[#expected+1]={c,"snapshot",s.base}
                    for n,op in ipairs(order) do
                        eq(op[1],expected[cut-n+1][1],"reverse target")
                        eq(op[2],expected[cut-n+1][2],"reverse slot")
                        eq(op[3],expected[cut-n+1][3],"reverse preimage")
                    end
                    eq(traps,0,"mixed hostile objects untouched")
                end
            end
            -- Continue restoring all earlier entries even after one restore fails.
            local total,rollback_calls=0,0
            local continue_restore=isolated({rawset=function(t,k,value)
                total=total+1
                if k=="snapshot" then
                    if rollback_calls==0 then rawset(t,k,value) end
                    rollback_calls=rollback_calls+1
                    error(hostile)
                end
                return rawset(t,k,value)
            end})
            tx,s,c,l=fixture("full",continue_restore);b=baseline(s,c,l)
            v,err=scoped(tx,s,c,l);refusal(v,err,"rollback","snapshot restore failure")
            eq(tx:Poisoned(),true,"version restore failure poisons")
            eq(rollback_calls,2,"snapshot attempted and restore attempted")
            test(c.snapshot~=b.snapshot,"failed version restore not claimed atomic")
            for i,op in ipairs(s.writes) do eq(select(2,get(op.anchor,op.index)),b.writes[i],"continued cell recovery") end
            for i,op in ipairs(s.publications) do eq(rawget(op.target,op.key),b.pubs[i],"continued callback recovery") end
            eq(total,10,"raw restore continues after snapshot failure")
            tx,s,c,l=fixture("full")
            b=baseline(s,c,l)
            local old_c=l.classes.L.cards[1].init
            local setter=must(Anchor.Get(l.entry,"setter"));setter(40)
            receipt=must(scoped(tx,s,c,l))
            local number,flag,empty=l.classes.K.cards[2]:init()
            eq(number,45,"all new joins before writes")
            eq(flag,false,"false shared");eq(empty,nil,"nil shared")
            eq(old_c(),142,"unselected old wrapper sees shared helper")
            eq(l.classes.K.cards[3]:init(),209,"other group cell/callback")
            eq(receipt.snapshot.revision,1,"whole group one revision")
            eq(receipt.snapshot.functions.revision,1,"all functions one revision")
            eq(_tx_runs,1,"full no initialization/wiring replay")
            -- Continued candidate and partial publication preserve pending.
            tx,s,c,l=fixture("full")
            s=must(Cards.Select(must(Cards.Compare(c.snapshot,full)),{"card:1:K:2"}))
            must(scoped(tx,s,c,l))
            local diff=must(Cards.Compare(c.snapshot,full))
            test(#diff.changed>0,"unselected B remains pending")
            eq(l.classes.K.cards[3]:init(),100,"unneeded other function untouched")
            l.snapshot=c.snapshot
            s=must(Cards.Select(diff,{"card:1:K:3"}))
            must(scoped(tx,s,c,l))
            eq(c.snapshot.revision,2,"second transaction revision")
            eq(l.classes.K.cards[3]:init(),209,"second group applied")
            -- Join failure may alter only new closures, never live cells/version.
            tx,s,c,l=fixture("full");b=baseline(s,c,l)
            local joined=0
            debug.upvaluejoin=function(...) joined=joined+1;join(...);error(hostile) end
            v,err=scoped(tx,s,c,l);refusal(v,err,"capability","join after throw")
            unchanged(s,c,l,b,"join failure");eq(joined,1,"join stops first fault")
            eq(tx:Poisoned(),false,"discarded candidate join not live poison")
            -- No-op native join cannot masquerade as successful sharing.
            tx,s,c,l=fixture("full");b=baseline(s,c,l)
            debug.upvaluejoin=function() end
            v,err=scoped(tx,s,c,l);refusal(v,err,"capability","no-op join")
            unchanged(s,c,l,b,"join postimage refusal")
            eq(tx:Poisoned(),false,"no-op join has no live poison")
            -- Never rejoin a currently published destination closure.
            tx,s,c,l=fixture("full");b=baseline(s,c,l)
            s.joins[1].fn=must(Anchor.Get(l.entry,"helper"))
            v,err=scoped(tx,s,c,l)
            eq(v,nil,"published closure join refused")
            unchanged(s,c,l,b,"no live closure rejoin")
            -- Actual hot old consumer, not -joff or a cold-only assertion.
            if type(real_jit)=="table" and real_jit.status() then
                tx,s,c,l=fixture("full")
                local old=l.classes.L.cards[1].init
                local hot=assert(loadstring("return function(fn) local sum=0 for i=1,10000 do sum=sum+fn() end return sum/10000 end"))()
                real_jit.flush()
                eq(hot(old),105,"warm original consumer")
                local util=require("jit.util")
                local traced=false
                for i=1,1000 do if util.traceinfo(i) then traced=true;break end end
                test(traced,"real hot trace exists")
                must(scoped(tx,s,c,l))
                eq(hot(old),106,"hot old consumer sees new shared helper")
                eq(real_jit.status(),true,"JIT remains on")
            end
        else
            print("CardCommitSpec: real new-closure joins/hot-JIT cases not run (Lua5.1)")
        end
        eq(traps,0,"all hostile objects untouched")
    end)
    reset()
    for _,key in ipairs(globals) do rawset(_G,key,saved[key]) end
    if not ok then error(problem) end
    for _,label in ipairs(failures) do print("FAIL CardCommitSpec: "..label) end
    return {passed=passed,failed=failed}
end
return M
