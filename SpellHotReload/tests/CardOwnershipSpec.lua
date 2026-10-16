local Planning=require("SpellHotReload.tests.PlanningFixture")
-- Card-owned raw ownership/publication policy. Synthetic inputs, no game chunks.
-- Lua5.1 presence-only join permits zero-join metadata/raw cases, never sharing.
local M = {}
local serial = 0
function M.run(opts)
    opts = opts or {}
    local Card = require("SpellHotReload.Adapters.Card.Card")
    local Load = require("SpellHotReload.Load.AnchorLoad")
    local Versions = require("SpellHotReload.Adapters.Card.Card")
    local Cards = require("SpellHotReload.Adapters.Card.CardVersions")
    local Guard = require("SpellHotReload.Apply.CommitCheck")
    local passed, failed, failures = 0, 0, {}
    local function check(v, label)
        if v then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end
    end
    local function eq(a,b,label) check(rawequal(a,b),label) end
    local function must(v,err) assert(v,type(err)=="table" and err.message or err);return v,err end
    local names={"before","init","frame","render","beforedel","del","after"}
    local methods={"CaptureOwnership","CheckOwnership","CheckCallbackRead","CheckPublications","CheckJoinDestinations"}
    local originals={}
    for _,name in ipairs(methods) do originals[name]=Card[name] end
    local globals,keys={},{"boss","_editor_class","_tmp_sc","_ownership_runs"}
    for _,key in ipairs(keys) do globals[key]=rawget(_G,key) end
    local get,set,join,id=debug.getupvalue,debug.setupvalue,debug.upvaluejoin,debug.upvalueid
    local saved_jit=rawget(_G,"jit")
    local traps,mutations=0,0
    local hostile=setmetatable({},{
        __index=function() traps=traps+1;error("unsafe read") end,
        __newindex=function() traps=traps+1;error("unsafe write") end,
        __tostring=function() traps=traps+1;error("unsafe stringify") end})
    local function refusal(v,err,phase,code,message,key,label)
        eq(v,nil,label.." refused");eq(type(err),"table",label.." structured")
        if type(err)=="table" then
            eq(err.phase,phase,label.." phase");eq(err.code,code,label.." code")
            eq(err.message,message,label.." message");eq(err.file,"Owners_Boss.lua",label.." file")
            eq(err.unit_key,key,label.." unit")
        end
    end
    local function direct()
        local a,b,other,placeholder={is_combat=true},{is_combat=true},{is_combat=true},{is_combat=false}
        for _,name in ipairs(names) do a[name]=function() end;b[name]=function() end end
        local classes={K={cards={placeholder,a,b}},L={cards={other}}}
        local descriptor={kind="card",callbacks={init=true}}
        local match={units={
            {key="card:K",context={class_key="K",layout={{kind="other"},descriptor,descriptor}}},
            {key="card:L",context={class_key="L",layout={descriptor}}},
        }}
        local entry={file="Owners_Boss.lua"}
        return match,classes,entry,a,b,other,placeholder
    end
    local function metadata()
        local match,classes,entry,a,b,c,p=direct()
        local owners,ownership=must(Card.CaptureOwnership(match,classes,entry))
        local base={file=entry.file,units={
            A={class_key="K",slot=2,card=a},B={class_key="K",slot=3,card=b},C={class_key="L",slot=1,card=c}}}
        return {classes=classes,ownership=ownership},base,classes,a,b,c,p,owners
    end
    local source=table.concat({
        "local state=4","local function helper() return state+1 end",
        "_ownership_runs=_ownership_runs+1",
        "_editor_class['K'].cards={boss.move.New(0,0,1)}",
        "_tmp_sc=boss.card.New('A',1,2,3,100)",
        "function _tmp_sc:init() return helper() end",
        "function _tmp_sc:frame() return 10 end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
        "_tmp_sc=boss.card.New('B',1,2,3,100)",
        "function _tmp_sc:init() return helper() end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
    },"\n")
    local function real_fixture()
        for _,name in ipairs(methods) do Card[name]=originals[name] end
        debug.getupvalue,debug.setupvalue,debug.upvaluejoin,debug.upvalueid=get,set,join,id
        if not join then debug.upvaluejoin=function() error("presence only, no sharing") end end
        rawset(_G,"jit",saved_jit)
        local defaults={}
        for _,name in ipairs(names) do defaults[name]=function() end end
        _ownership_runs=0;_editor_class={K={}}
        boss={card={New=function(name)
            local c={name=name,is_combat=true}
            for cb,fn in next,defaults do c[cb]=fn end
            return c
        end},move={New=function() return {is_combat=false} end}}
        serial=serial+1
        local sid="CardOwnershipSpec:"..serial
        local entry=must(Load.Capture(source,{name="Owners_Boss.lua",
            capability={getupvalue=true,setupvalue=true,upvaluejoin=true}}))
        entry.file="Owners_Boss.lua"
        local capture=must(Versions.SeedVersions(entry,sid,_editor_class,defaults))
        local content=source:gsub("return 10 end","return 20 end")
        local selection=must(Cards.Select(must(Planning.Report(capture,content)),{"card:1:K:2"}))
        local live={capture=capture,snapshot=capture.snapshot,entry=entry,session_id=sid,
            classes=_editor_class,content=content}
        eq(#selection.joins,0,"dispatch fixture has zero joins")
        return selection,capture,live
    end
    local function isolated_commit()
        local path="SpellHotReload/Apply/CardCommit.lua"
        local text=opts.sources and opts.sources[path]
        local chunk=text and assert(loadstring(text,"@candidate/"..path))
            or assert(loadfile("THDiMS/game/plugin/SpellHotReload/"..path))
        return chunk()
    end
    local ok,problem=pcall(function()
        -- Policy must read raw identities without debug writes/cache callbacks.
        debug.setupvalue=function() mutations=mutations+1;error("policy writes") end
        debug.upvaluejoin=function() mutations=mutations+1;error("policy joins") end
        rawset(_G,"jit",{flush=function() mutations=mutations+1;error("policy flushes") end})
        local match,classes,entry,a,b,c,p=direct()
        local owners,ownership=must(Card.CaptureOwnership(match,classes,entry))
        eq(#owners,3,"all combat descriptors captured");eq(#ownership,2,"all class lists captured")
        eq(owners[1].card,a,"genuine original card");eq(owners[1].slot,2,"placeholder counts")
        eq(ownership[1].class,classes.K,"class identity");eq(ownership[1].list,classes.K.cards,"list identity")
        eq(ownership[1].slots[1],p,"placeholder ownership")
        for _,name in ipairs(names) do eq(owners[1].callbacks[name],a[name],"original callback "..name) end
        local old=owners[1].callbacks.frame;a.frame=function() end
        eq(owners[1].callbacks.frame,old,"metadata snapshot not live alias")
        local again=must(Card.CaptureOwnership(match,classes,entry))
        eq(again[1].callbacks.frame,a.frame,"fresh explicit capture, no module cache")
        check(again~=owners,"independent capture metadata")
        for _,case in ipairs({
            {"missing class",function(m,cs) cs.K=nil end,"first-load class/list layout unavailable"},
            {"class metatable",function(m,cs) setmetatable(cs.K,getmetatable(hostile)) end,"first-load class/list layout unavailable"},
            {"sparse list",function(m,cs) cs.K.cards[2]=nil end,"first-load class/list layout unavailable"},
            {"extra key",function(m,cs) cs.K.cards.note=true end,"first-load class/list layout unavailable"},
            {"list metatable",function(m,cs) setmetatable(cs.K.cards,getmetatable(hostile)) end,"first-load class/list layout unavailable"},
            {"shared slot",function(m,cs) cs.K.cards[3]=cs.K.cards[2] end,"invalid or multiply owned first-load card"},
            {"card metatable",function(m,cs) setmetatable(cs.K.cards[2],getmetatable(hostile)) end,"invalid or multiply owned first-load card"},
            {"not combat",function(m,cs) cs.K.cards[2].is_combat=false end,"combat descriptor does not own a combat card"},
        }) do
            match,classes,entry=direct();case[2](match,classes)
            local v,err=Card.CaptureOwnership(match,classes,entry)
            refusal(v,err,"capture","ownership",case[3],"card:K",case[1])
        end
        local capture,base,cs
        capture,base,cs,a,b,c,p=metadata()
        local seen=must(Card.CheckOwnership(capture,base,cs))
        eq(seen[a],true,"combat in transient set");eq(seen[p],true,"placeholder in transient set")
        eq(seen[c],true,"other class included")
        for _,case in ipairs({
            {"registry",function(cap,bs,cl) cap.classes={} end,"class registry or ownership unavailable"},
            {"ownership sparse",function(cap) cap.ownership[1]=nil end,"class registry or ownership unavailable"},
            {"units metatable",function(cap,bs) setmetatable(bs.units,getmetatable(hostile)) end,"class registry or ownership unavailable"},
            {"class replaced",function(cap,bs,cl) cl.K={} end,"first-load class/list ownership changed"},
            {"list replaced",function(cap,bs,cl) cl.K.cards={} end,"first-load class/list ownership changed"},
            {"owner duplicate",function(cap) cap.ownership[2]=cap.ownership[1] end,"first-load class/list ownership changed"},
            {"list sparse",function(cap,bs,cl) cl.K.cards[1]=nil end,"first-load class/list ownership changed"},
            {"slot replaced",function(cap,bs,cl) cl.K.cards[1]={} end,"first-load slot ownership changed"},
            {"unselected replaced",function(cap,bs,cl) cl.K.cards[3]={is_combat=true} end,"first-load slot ownership changed"},
            {"cross-class sharing",function(cap,bs,cl) cl.L.cards[1]=cl.K.cards[2];cap.ownership[2].slots[1]=cl.K.cards[2] end,"first-load slot ownership changed"},
        }) do
            capture,base,cs=metadata();case[2](capture,base,cs)
            local v,err=Card.CheckOwnership(capture,base,cs)
            refusal(v,err,"commit","ownership",case[3],nil,case[1])
        end
        for _,case in ipairs({
            {"unit slot",function(u) u.slot=1 end},
            {"unit card",function(u) u.card={} end},
            {"unit class",function(u) u.class_key="missing" end},
            {"combat changed",function(u) u.card.is_combat=false end},
        }) do
            capture,base,cs=metadata();case[2](base.units.A)
            local v,err=Card.CheckOwnership(capture,base,cs)
            refusal(v,err,"commit","ownership","published card no longer owns its combat slot","A",case[1])
        end
        capture,base,cs,a,b=metadata();seen=must(Card.CheckOwnership(capture,base,cs))
        for _,name in ipairs(names) do
            eq(Card.CheckCallbackRead({target=a,key=name,value=a[name]},seen,base.file),true,"read "..name)
            local pub={target=a,key=name,before=a[name],value=function() end,unit_key="A"}
            eq(Card.CheckPublications({pub},base,seen),true,"publication "..name)
            eq(a[name],pub.before,"no publication "..name)
        end
        a.frame=nil
        eq(Card.CheckCallbackRead({target=a,key="frame",value=nil},seen,base.file),true,"missing raw read")
        eq(Card.CheckPublications({{target=a,key="frame",before=nil,value=function() end,unit_key="A"}},base,seen),
            true,"missing raw publication preimage")
        for _,read in ipairs({{target={},key="init"},{target=a,key="name",value=a.name},
            {target=a,key="frame",value=function() end},{target=hostile,key="init"}}) do
            local v,err=Card.CheckCallbackRead(read,seen,base.file)
            refusal(v,err,"commit","stale","raw callback read changed",nil,"bad read")
        end
        local function publication() return {target=b,key="init",before=b.init,value=function() end,unit_key="B"} end
        for _,case in ipairs({
            {"key",function(pub) pub.key="unknown" end,"unsupported","raw callback publication required",nil},
            {"value",function(pub) pub.value=false end,"unsupported","raw callback publication required",nil},
            {"target meta",function(pub) pub.target=hostile end,"unsupported","raw callback publication required",nil},
            {"unit",function(pub) pub.unit_key="unknown" end,"stale","callback publication owner/preimage changed","unknown"},
            {"foreign",function(pub) pub.target=a end,"stale","callback publication owner/preimage changed","B"},
            {"preimage",function(pub) pub.before=function() end end,"stale","callback publication owner/preimage changed","B"},
        }) do
            local pub=publication();case[2](pub)
            local v,err=Card.CheckPublications({pub},base,seen)
            refusal(v,err,"commit",case[3],case[4],case[5],"bad publication "..case[1])
        end
        local pub=publication()
        local v,err=Card.CheckPublications({pub,pub},base,seen)
        refusal(v,err,"commit","ownership","duplicate raw publication","B","duplicate publication")
        -- Defaults, original helper, any callback and anchor are all live closures.
        local anchor,default,helper,callback,new_a,new_b=function() end,function() end,function() end,
            function() end,function() end,function() end
        local s={anchor=anchor,base={file=base.file,defaults={init=default},functions={units={h={fn=helper}}},
            units={B={callbacks={init={fn=callback}}}}},joins={{fn=new_a},{fn=new_b}},
            writes={{value=new_a}},publications={{value=new_b}}}
        eq(Card.CheckJoinDestinations(s),true,"new selected closure destinations")
        for _,fn in ipairs({anchor,default,helper,callback,function() end}) do
            s.joins[1].fn=fn
            v,err=Card.CheckJoinDestinations(s)
            refusal(v,err,"commit","unsupported","joins require unpublished destination closures",nil,"unsafe join")
        end
        for _,fn in ipairs({anchor,default,helper,callback}) do
            s.joins[1].fn=fn;s.writes[1].value=fn
            v,err=Card.CheckJoinDestinations(s)
            refusal(v,err,"commit","unsupported","joins require unpublished destination closures",nil,"live closure claimed as destination")
        end
        s.writes[1].value=new_a
        s.joins[1].fn=callback;s.publications[1].value=callback
        eq(Card.CheckJoinDestinations(s),nil,"published closure rejected even when selected as value")
        eq(mutations,0,"direct policies never mutate/join/flush");eq(traps,0,"direct policies never invoke metatables")
        -- Actual capture/guard/transaction call sites must consume Card policy.
        local selection,cap,live=real_fixture()
        local original_snapshot=cap.snapshot
        local marker={phase="capture",code="ownership",message="adapter capture refused",file=live.entry.file}
        local called=0
        Card.CaptureOwnership=function(m,cls,e)
            called=called+1;eq(cls,live.classes,"capture registry delegation");eq(e,live.entry,"capture entry delegation")
            check(#m.units>0,"capture complete match delegation");return nil,marker
        end
        v,err=Versions.SeedVersions(live.entry,live.session_id,live.classes,cap.snapshot.defaults)
        eq(called,1,"LoadVersions consumes adapter capture");eq(v,nil,"capture policy stops seed");eq(err,marker,"capture error identity")
        Card.CaptureOwnership=originals.CaptureOwnership
        for _,method in ipairs({"CheckOwnership","CheckCallbackRead","CheckPublications"}) do
            selection,cap,live=real_fixture();called=0
            marker={phase="commit",code="ownership",message="adapter refused "..method,file=live.entry.file}
            Card[method]=function(...)
                called=called+1
                if method=="CheckOwnership" then
                    eq(select(1,...),cap,"guard capture delegation");eq(select(2,...),selection.base,"guard base delegation")
                    eq(select(3,...),live.classes,"guard classes delegation")
                elseif method=="CheckCallbackRead" then check(select(1,...).target~=nil,"guard callback record")
                else eq(select(1,...),selection.publications,"guard publication array") end
                return nil,marker
            end
            v,err=Guard.Check(selection,cap,live)
            eq(called,1,"CommitCheck consumes "..method);eq(v,nil,"guard policy stops transaction");eq(err,marker,"guard policy error identity")
            eq(cap.snapshot,selection.base,"guard keeps version");eq(_ownership_runs,1,"guard never initializes again")
            Card[method]=originals[method]
        end
        selection,cap,live=real_fixture();called=0
        marker={phase="commit",code="unsupported",message="adapter join policy refused",file=live.entry.file}
        Card.CheckJoinDestinations=function(sealed)
            called=called+1
            check(sealed~=selection,"transaction supplies sealed selection")
            check(sealed.publications~=selection.publications,"transaction seals action arrays")
            eq(sealed.base,selection.base,"transaction uses actual published base")
            return nil,marker
        end
        local tx=must(isolated_commit().New(live.session_id))
        Card.CheckJoinDestinations=originals.CheckJoinDestinations
        local old_frame=live.classes.K.cards[2].frame
        local flushes=0;rawset(_G,"jit",{flush=function() flushes=flushes+1 end})
        local ran=tx:Run(function(token)
            v,err=tx:Commit(token,selection,cap,live)
            eq(v,nil,"kernel policy refusal");eq(err.message,marker.message,"kernel preserves refusal message")
            eq(err.code,marker.code,"kernel preserves refusal code")
            eq(tx:Check(token),true,"preparation refusal does not consume token")
        end)
        eq(ran,true,"policy refusal scope returns");eq(called,1,"CardCommit consumes adapter join rule")
        eq(flushes,0,"policy refusal before flush")
        eq(cap.snapshot,selection.base,"policy refusal before version install")
        eq(live.classes.K.cards[2].frame,old_frame,"policy refusal before publication")
        eq(_ownership_runs,1,"no initialization replay");eq(tx:Poisoned(),false,"preparation refusal not poison")
        eq(tx:Release(),true,"controller release")
        eq(traps,0,"all hostile metatables untouched")
    end)
    for _,name in ipairs(methods) do Card[name]=originals[name] end
    debug.getupvalue,debug.setupvalue,debug.upvaluejoin,debug.upvalueid=get,set,join,id
    rawset(_G,"jit",saved_jit)
    for _,key in ipairs(keys) do rawset(_G,key,globals[key]) end
    if not ok then failed=failed+1;failures[#failures+1]="unexpected: "..(type(problem)=="string" and problem or "non-string error") end
    print(string.format("CardOwnershipSpec: %d passed / %d failed",passed,failed))
    for _,failure in ipairs(failures) do print("  FAIL: "..failure) end
    return {passed=passed,failed=failed,failures=failures}
end
return M
