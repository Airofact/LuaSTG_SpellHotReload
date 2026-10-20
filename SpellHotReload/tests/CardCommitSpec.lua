local Planning=require("SpellHotReload.tests.PlanningFixture")
-- Synthetic first loads and fault injection, never engine/game chunks.
-- Real Local/Card fragments and LuaJIT sharing; one neutral file publication.
local M = {}
local serial=0
function M.run(opts)
    opts = opts or {}
    local Tx = opts.transaction or require("SpellHotReload.Apply.FileCommit")
    local Load = require("SpellHotReload.Load.AnchorLoad")
    local Capture = require("SpellHotReload.Adapters.Card.Card")
    local Local = require("SpellHotReload.Adapters.Local.Local")
    local Source = require("SpellHotReload.Source.FileAnalysis")
    local Compose = require("SpellHotReload.Source.Compose")
    local Guard = require("SpellHotReload.Apply.CommitCheck")
    local Anchor = require("SpellHotReload.Load.Anchor")
    local passed, failed, failures = 0, 0, {}
    local controllers={}
    local function controller(module,sid)
        local tx,err=module.New(sid)
        if tx then controllers[#controllers+1]=tx end
        return tx,err
    end
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
    local keya,keyb="card:1:K:2","card:1:K:3"
    local function group(snapshot,owner)
        for _,g in ipairs(snapshot.owners) do if g.owner==owner then return g end end
        error("missing real owner")
    end
    local function fragment(p,owner)
        for _,r in ipairs(p.entries) do if r.owner==owner then return r.fragment end end
        error("missing prepared owner")
    end
    local function records(p,key)
        local out={}
        for _,r in ipairs(p.entries) do
            for _,record in ipairs(r.fragment[key]) do out[#out+1]=record end
        end
        return out
    end
    local function writes(p) return records(p,"cell_writes") end
    local function publications(p) return records(p,"raw_writes") end
    local function joins(p) return records(p,"joins") end
    local function fragments(p)
        local out={};for _,r in ipairs(p.entries) do out[#out+1]=r.fragment end
        return out
    end
    local function prepare(l,bytes,ids)
        l.content,l.generation,l.snapshot=bytes,l.generation+1,l.capture.snapshot
        local f=l.fixture
        local facts=must(Source.Build(bytes))
        local d=must(Planning.Discover(f,facts,l.generation))
        local p=must(Planning.Prepare(f,d,{mode="file",root_ids=ids,refresh=f.refresh}))
        eq(#p.dependencies.safe_roots,#ids,"every requested root is genuinely safe")
        eq(#p.dependencies.blocked_roots,0,"no failure masked by blocked roots")
        return p,d
    end
    local function changed(l)
        -- A NEW discovery, actual full-file location and version comparison;
        -- an empty selected set does not publish or treat analysis as permission.
        local p=prepare(l,l.content,{})
        local view=fragment(p,Capture).card_plan.view
        local n=0
        for _,key in ipairs(view.base.order) do
            if view.by_key[key].changed then n=n+1 end
        end
        return n
    end
    local function fixture(kind,module)
        reset()
        _tx_runs=0;_editor_class={K={},L={}}
        boss={card={New=function(name)
            local card={name=name,is_combat=true}
            for _,cb in ipairs(names) do card[cb]=defaults[cb] end
            return card
        end},move={New=function() return {is_combat=false} end}}
        serial=serial+1
        local sid="CardCommitSpec:"..tostring(serial)
        local entry=must(Load.Capture(source,{name="Tx_Boss.lua"}))
        must(entry.reloadable,entry.reason);entry.file="Tx_Boss.lua"
        local f=must(Planning.Capture(entry,sid,_editor_class,defaults))
        local c=f.capture
        local l={capture=c,snapshot=c.snapshot,entry=entry,session_id=sid,
            classes=_editor_class,content=source,generation=0,fixture=f}
        f.refresh=function() return l end
        local content=kind=="raw" and source:gsub("return 10 end","return 20 end")
            or (kind=="cell" and source:gsub("return 100 end","return 200 end") or full)
        local ids=kind=="cell" and {keyb} or {keya,keyb}
        local p=prepare(l,content,ids)
        return must(controller(module or Tx,sid)),p,c,l
    end
    local function scoped(tx,p,c,l,registered,consumed)
        if registered then return Planning.Publish(l.fixture,p,tx) end
        local ran,value,err=tx:Run(function(token)
            local v,e=tx:Commit(token,p.operation,fragments(p),l,l.fixture.refresh)
            if consumed then
                local again,why=tx:Commit(token,p.operation,fragments(p),l,l.fixture.refresh)
                eq(again,nil,"attempted commit token cannot be reused")
                eq(type(why),"table","consumed token structured refusal")
                eq(why and why.code,"phase","attempted commit consumes token")
            end
            return v,e
        end)
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
        for i,op in ipairs(writes(s)) do result.writes[i]=select(2,get(op.anchor,op.index)) end
        for i,op in ipairs(publications(s)) do result.pubs[i]=rawget(op.target,op.key) end
        return result
    end
    local function unchanged(s,c,l,b,label)
        eq(c.snapshot,b.snapshot,label.." snapshot")
        eq(l.entry.anchor,b.anchor,label.." anchor")
        eq(l.entry.loaded_source,b.source,label.." load source")
        eq(_tx_runs,b.runs,label.." no miniature first-load replay")
        for i,op in ipairs(writes(s)) do
            eq(select(2,get(op.anchor,op.index)),b.writes[i],label.." cell "..i)
        end
        for i,op in ipairs(publications(s)) do
            eq(rawget(op.target,op.key),b.pubs[i],label.." callback "..i)
        end
    end
    local function isolated(overrides)
        local chunk=assert(loadfile(assert(opts.module_path,"isolated module path required")))
        setfenv(chunk,setmetatable(overrides or {},{__index=_G}))
        return chunk()
    end
    local ok,problem=pcall(function()
        must(Anchor.Supported(Compose.Capability(debug)))
        eq(Tx.Kind,"SpellHotReload.FileCommit","kind")
        eq(Tx.Version,1,"version")
        for _,sid in ipairs({"",false,4,{}}) do
            local v,err=Tx.New(sid)
            eq(v,nil,"invalid session");eq(type(err),"table","invalid session error")
        end
        -- Raw-only publication works without relying on a fake shared join.
        local tx,s,c,l=fixture("raw")
        local b=baseline(s,c,l)
        eq(#joins(s),0,"raw-only zero joins");eq(#writes(s),0,"raw-only zero cells")
        local flushes=0
        rawset(_G,"jit",{flush=function(...) flushes=flushes+1;eq(select("#",...),0,"whole cache") end})
        local receipt=must(scoped(tx,s,c,l,true))
        eq(receipt.kind,"SpellHotReload.FileCommit.Receipt","receipt kind")
        eq(receipt.snapshot,c.snapshot,"installed snapshot returned")
        eq(receipt.changed,true,"publication changed")
        eq(c.snapshot.revision,1,"revision after whole group")
        eq(flushes,1,"one flush for transaction")
        eq(l.entry.anchor,b.anchor,"unique anchor retained")
        eq(l.entry.loaded_source,source,"load baseline retained")
        eq(_tx_runs,1,"miniature first-load chunk ran once")
        for _,op in ipairs(publications(s)) do eq(rawget(op.target,op.key),op.value,"all raw callbacks installed") end
        eq(l.classes.K.cards[2]:frame(),20,"A next call")
        eq(l.classes.K.cards[3]:frame(),20,"B next call")
        eq(changed(l),0,"published definitions compare clean")

        tx,s,c,l=fixture("cell")
        eq(#joins(s),0,"constant function needs no new joins")
        eq(#writes(s),1,"one genuine shared function cell")
        local old_callback=l.classes.K.cards[3].init
        receipt=must(scoped(tx,s,c,l))
        eq(receipt.snapshot.revision,1,"common revision installed")
        eq(group(receipt.snapshot,Local).state.by_name.other.definition_version,2,"actual Local definition version")
        eq(receipt.owner_deltas[1].owner,Local,"actual Local delta owner")
        eq(receipt.owner_deltas[1].changed,true,"Local delta changed")
        eq(receipt.owner_deltas[2].changed,false,"Card wrapper delta unchanged")
        eq(old_callback(),200,"original callback sees replaced anchor cell")
        eq(l.classes.K.cards[3].init,old_callback,"helper-only keeps wrapper identity")
        -- Optional callback deletion publishes its captured genuine default.
        tx,s,c,l=fixture("raw")
        l.content=source:gsub("function _tmp_sc:frame%(%) return 10 end","")
        s=prepare(l,l.content,{keya})
        receipt=must(scoped(tx,s,c,l))
        eq(l.classes.K.cards[2].frame,defaults.frame,"deleted optional default restored")
        eq(group(c.snapshot,Capture).state.units["card:1:K:2"].callbacks.frame.body,nil,"deleted version body")
        test(changed(l)>0,"unselected deletion pending")
        -- Failed default restoration or snapshot install must undo deletion,
        -- including native operations which mutate and then throw.
        for _,after in ipairs({false,true}) do
            for cut=1,2 do
                local writes=0
                local deletion_tx=isolated({rawset=function(target,key,value)
                    writes=writes+1
                    if writes==cut then
                        if after then rawset(target,key,value) end
                        error("deletion journal fault")
                    end
                    return rawset(target,key,value)
                end})
                tx,s,c,l=fixture("raw",deletion_tx)
                l.content=source:gsub("function _tmp_sc:frame%(%) return 10 end","")
                s=prepare(l,l.content,{keya})
                local before=baseline(s,c,l)
                local v,e=scoped(tx,s,c,l)
                refusal(v,e,"publish","deletion rollback cut "..cut)
                unchanged(s,c,l,before,"deletion rollback")
                eq(group(c.snapshot,Capture).state.units["card:1:K:2"].callbacks.frame.definition_version,1,"failed deletion version retained")
                eq(tx:Poisoned(),false,"successful deletion rollback not poisoned")
            end
        end
        -- Bodies are not run by commit, even bodies which immediately throw.
        tx,s,c,l=fixture("raw")
        l.content=source:gsub("return 10 end","error('body must not run') end")
        s=prepare(l,l.content,{keya})
        must(scoped(tx,s,c,l))
        eq(_tx_runs,1,"throwing candidate body not executed by commit")
        -- No-op validates ownership/scope, consumes once but never flushes.
        tx,s,c,l=fixture("raw")
        s=prepare(l,source,{})
        flushes=0;rawset(_G,"jit",{flush=function() flushes=flushes+1 end})
        local duplicate
        local ran=tx:Run(function(token)
            receipt=must(tx:Commit(token,s.operation,fragments(s),l,l.fixture.refresh))
            local v,err=tx:Commit(token,s.operation,fragments(s),l,l.fixture.refresh);duplicate=err;eq(v,nil,"token once")
        end)
        eq(ran,true,"no-op scope");eq(receipt.changed,false,"no-op receipt")
        eq(receipt.snapshot,s.operation.base_snapshot,"no-op baseline identity");eq(flushes,0,"no-op cache untouched")
        eq(duplicate.code,"phase","consumed token refusal")
        -- Invalid scope/session, stale bytes, missing, owner/revision failures.
        local changes={
            {"bytes",function(_,_,v) v.content=v.content.." " end,"stale"},
            {"session",function(_,_,v) v.session_id="other" end,"phase"},
            {"capture",function(_,_,v) v.capture={} end,"stale"},
            {"revision",function(v) v.operation.base_snapshot={} end,"ownership"},
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
        local v,err=tx:Commit({},s.operation,fragments(s),l,l.fixture.refresh)
        refusal(v,err,"phase","outside scope")
        unchanged(s,c,l,b,"outside")
        local result
        tx:Run(function(token) result=token end)
        v,err=tx:Commit(result,s.operation,fragments(s),l,l.fixture.refresh);refusal(v,err,"phase","expired scope")
        local tx2=must(controller(Tx,l.session_id))
        tx:Run(function(token)
            local a,e=tx2:Commit(token,s.operation,fragments(s),l,l.fixture.refresh);refusal(a,e,"phase","foreign controller")
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
                v,err=scoped(tx,s,c,l,false,true)
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
        -- Card's captured callback cannot be erased externally and then adopted
        -- by forging read/preimage metadata. Legitimate absent raw rollback is
        -- covered by FileCommitSpec's genuine first-load absent-field fixture.
        tx,s,c,l=fixture("raw")
        local card=l.classes.K.cards[2]
        card.frame=nil
        b=baseline(s,c,l)
        v,err=scoped(tx,s,c,l);refusal(v,err,"stale","external nil callback")
        eq(rawget(card,"frame"),nil,"external nil remains unchanged")
        unchanged(s,c,l,b,"nil drift refusal")
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
        local peer=must(controller(poison_tx,l.session_id))
        v,err=scoped(tx,s,c,l);refusal(v,err,"rollback","poison raw")
        eq(tx:Poisoned(),true,"poison flag");eq(peer:Poisoned(),true,"session peer poisoned")
        v,err=peer:Run(function() error("must not run") end)
        eq(v,nil,"poison blocks Run");eq(err.code,"poisoned","peer poison code")
        v,err=poison_tx.New(l.session_id);eq(v,nil,"same session recreation refused");eq(err.code,"poisoned","new poison code")
        eq(tx:Release(),true,"poison release");eq(tx:Release(),true,"idempotent release")
        eq(tx:Poisoned(),true,"release does not clear poison")
        test(controller(poison_tx,l.session_id..":new")~=nil,"different session can start")
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
        local failing_seal=isolated({require=function(name)
            if name=="SpellHotReload.Apply.CommitCheck" then
                local out={};for key,value in next,Guard do out[key]=value end
                out.Seal=function() error(hostile) end
                return out
            end
            return require(name)
        end})
        tx,s,c,l=fixture("raw",failing_seal);b=baseline(s,c,l)
        local seal_scope=tx:Run(function(token)
            v,err=tx:Commit(token,s.operation,fragments(s),l,l.fixture.refresh)
            refusal(v,err,"ownership","metadata throw")
            eq(tx:Check(token),true,"failed preparation leaves token usable")
        end)
        eq(seal_scope,true,"failed preparation scope completed")
        unchanged(s,c,l,b,"failed preparation")
        eq(tx:Poisoned(),false,"preparation does not poison")
        -- Invalidation cannot rewrite the sealed action records via caller arrays.
        tx,s,c,l=fixture("raw")
        local original_value=publications(s)[1].value
        rawset(_G,"jit",{flush=function() publications(s)[1].value=function() return 999 end end})
        receipt=must(scoped(tx,s,c,l))
        eq(rawget(publications(s)[1].target,publications(s)[1].key),original_value,"sealed actions used")
        -- Table/plan metatables refuse before any cache/mutation side effect.
        tx,s,c,l=fixture("raw");b=baseline(s,c,l)
        setmetatable(fragment(s,Capture),{__index=function() traps=traps+1;error(hostile) end})
        v,err=scoped(tx,s,c,l);refusal(v,err,"ownership","fragment metatable")
        unchanged(s,c,l,b,"unsafe plan")
        tx,s,c,l=fixture("raw");b=baseline(s,c,l)
        setmetatable(l.classes.K.cards[2],{__newindex=function() traps=traps+1;error(hostile) end})
        v,err=scoped(tx,s,c,l);refusal(v,err,"ownership","target metatable")
        unchanged(s,c,l,b,"unsafe target")
        -- Reentrancy during trusted test primitives is refused, even at teardown.
        local reentered,released
        local reentry_tx=isolated({rawset=function(t,k,value)
            if tx then
                local a,e=tx:Commit({},s.operation,fragments(s),l,l.fixture.refresh);reentered=e;eq(a,nil,"nested commit blocked")
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
                local a,e=tx:Commit(token,s.operation,fragments(s),l,l.fixture.refresh);refusal(a,e,"phase","coroutine commit")
            end)
            eq(coroutine.resume(thread),true,"coroutine refusal returns")
        end)
        eq(tx:Release(),true,"release success")
        v,err=tx:Run(function() end);eq(v,nil,"released Run");eq(err.code,"stale","released code")
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
                eq(#writes(s)+#publications(s)+1,7,"mixed journal length")
                debug.setupvalue=function(fn,index,value)
                    return perform(fn,index,value,function() return set(fn,index,value) end)
                end
                v,err=scoped(tx,s,c,l,false,true);refusal(v,err,"publish","mixed cut "..cut)
                unchanged(s,c,l,b,"mixed rollback")
                eq(tx:Poisoned(),false,"mixed restored")
                eq(#order,cut,"all attempted operations restored")
                local expected={}
                for _,op in ipairs(writes(s)) do expected[#expected+1]={op.anchor,op.index,op.before} end
                for _,op in ipairs(publications(s)) do expected[#expected+1]={op.target,op.key,op.before} end
                expected[#expected+1]={c,"snapshot",s.operation.base_snapshot}
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
        for i,op in ipairs(writes(s)) do eq(select(2,get(op.anchor,op.index)),b.writes[i],"continued cell recovery") end
        for i,op in ipairs(publications(s)) do eq(rawget(op.target,op.key),b.pubs[i],"continued callback recovery") end
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
        eq(group(receipt.snapshot,Local).state.by_name.helper.definition_version,2,"actual helper version installed")
        eq(group(receipt.snapshot,Local).state.by_name.other.definition_version,2,"actual other version installed")
        eq(_tx_runs,1,"full no miniature chunk/wiring replay")
        -- Continued candidate and partial publication preserve pending.
        tx,s,c,l=fixture("full")
        s=prepare(l,full,{keya})
        must(scoped(tx,s,c,l))
        test(changed(l)>0,"unselected B remains pending")
        eq(l.classes.K.cards[3]:init(),100,"unneeded other function untouched")
        l.snapshot=c.snapshot
        s=prepare(l,full,{keyb})
        must(scoped(tx,s,c,l))
        eq(c.snapshot.revision,2,"second transaction revision")
        eq(l.classes.K.cards[3]:init(),209,"second group applied")
        -- Join failure may alter only new closures, never live cells/version.
        tx,s,c,l=fixture("full");b=baseline(s,c,l)
        local joined=0
        debug.upvaluejoin=function(...) joined=joined+1;join(...);error(hostile) end
        v,err=scoped(tx,s,c,l,false,true);refusal(v,err,"capability","join after throw")
        unchanged(s,c,l,b,"join failure");eq(joined,1,"join stops first fault")
        eq(tx:Poisoned(),false,"discarded candidate join not live poison")
        -- No-op native join cannot masquerade as successful sharing.
        tx,s,c,l=fixture("full");b=baseline(s,c,l)
        debug.upvaluejoin=function() end
        v,err=scoped(tx,s,c,l,false,true);refusal(v,err,"capability","no-op join")
        unchanged(s,c,l,b,"join postimage refusal")
        eq(tx:Poisoned(),false,"no-op join has no live poison")
        -- Never rejoin a currently published destination closure.
        tx,s,c,l=fixture("full");b=baseline(s,c,l)
        joins(s)[1].fn=must(Anchor.Get(l.entry,"helper"))
        v,err=scoped(tx,s,c,l)
        eq(v,nil,"published closure join refused")
        unchanged(s,c,l,b,"no live closure rejoin")
        -- Actual hot old consumer, not -joff or a cold-only assertion.
        must(type(real_jit)=="table" and type(real_jit.status)=="function" and real_jit.status(),
            "CardCommitSpec requires real LuaJIT with JIT enabled")
        do
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
        eq(traps,0,"all hostile objects untouched")
    end)
    reset()
    for _,tx in ipairs(controllers) do tx:Release() end
    for _,key in ipairs(globals) do rawset(_G,key,saved[key]) end
    if not ok then error(problem) end
    for _,label in ipairs(failures) do print("FAIL CardCommitSpec: "..label) end
    return {passed=passed,failed=failed}
end
return M
