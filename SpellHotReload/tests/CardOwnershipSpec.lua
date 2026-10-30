local Planning=require("SpellHotReload.tests.PlanningFixture")
-- Card's exact callback policy and common mechanical authority.
-- Miniature genuine first loads; no legacy commit facade or fake sharing.
local M={}
local serial=0
function M.run(opts)
    opts=opts or {}
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local Cards=require("SpellHotReload.Adapters.Card.CardVersions")
    local Reconcile=require("SpellHotReload.Adapters.Card.CardReconcile")
    local Target=require("SpellHotReload.Adapters.Card.CardTarget")
    local Local=require("SpellHotReload.Adapters.Local.Local")
    local Files=require("SpellHotReload.Pipeline.FileVersions")
    local Source=require("SpellHotReload.Source.FileAnalysis")
    local Load=require("SpellHotReload.Load.AnchorLoad")
    local Anchor=require("SpellHotReload.Load.Anchor")
    local Compose=require("SpellHotReload.Source.Compose")
    local Guard=require("SpellHotReload.Apply.CommitCheck")
    local passed,failed,failures=0,0,{}
    local controllers={}
    local function check(v,label)
        if v then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end
    end
    local function eq(a,b,label) check(rawequal(a,b),label) end
    local function must(v,e) assert(v,type(e)=="table" and e.message or e);return v,e end
    local function copy(v) local out={};for k,x in next,v do out[k]=x end;return out end
    local names={"before","init","frame","render","beforedel","del","after"}
    local capture_ownership=Card.CaptureOwnership
    local card_guard,card_reads=Cards.Guard,Cards.Reads
    local check_file,check_publications=Target.CheckFileDiscovery,Reconcile.CheckPublications
    local globals,keys={},{"boss","_editor_class","_tmp_sc","_ownership_runs"}
    for _,key in ipairs(keys) do globals[key]=rawget(_G,key) end
    local get,set,join,id=debug.getupvalue,debug.setupvalue,debug.upvaluejoin,debug.upvalueid
    local saved_jit=rawget(_G,"jit")
    local traps,mutations=0,0
    local hostile=setmetatable({},{
        __index=function() traps=traps+1;error("unsafe read") end,
        __newindex=function() traps=traps+1;error("unsafe write") end,
        __tostring=function() traps=traps+1;error("unsafe stringify") end})
    local function refusal(v,e,phase,code,message,key,label)
        eq(v,nil,label.." refused");eq(type(e),"table",label.." structured")
        if type(e)=="table" then
            eq(e.phase,phase,label.." phase");eq(e.code,code,label.." code")
            if message then eq(e.message,message,label.." message") else check(type(e.message)=="string",label.." safe message") end
            eq(e.file,"Owners_Boss.lua",label.." file");eq(e.unit_key,key,label.." unit")
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
    local keya,keyb,keyc="card:1:K:2","card:1:K:3","card:1:L:1"
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
        "_editor_class['L'].cards={}",
        "_tmp_sc=boss.card.New('C',1,2,3,100)",
        "function _tmp_sc:init() return helper() end",
        "table.insert(_editor_class['L'].cards,_tmp_sc)",
    },"\n")
    local function restore()
        Card.CaptureOwnership=capture_ownership
        Cards.Guard,Cards.Reads=card_guard,card_reads
        Target.CheckFileDiscovery,Reconcile.CheckPublications=check_file,check_publications
        debug.getupvalue,debug.setupvalue,debug.upvaluejoin,debug.upvalueid=get,set,join,id
        rawset(_G,"jit",saved_jit)
    end
    local function group(c,owner) return must(Files.GetAdapterRecords(c,owner)) end
    local function fragment(p,owner)
        for _,r in ipairs(p.entries) do if r.owner==owner then return r.fragment end end
        error("missing real prepared owner")
    end
    local function fragments(p)
        local out={};for _,r in ipairs(p.entries) do out[#out+1]=r.fragment end;return out
    end
    local function seal(p) return Guard.Seal(p.operation,fragments(p)) end
    local function real_fixture(bytes)
        restore()
        local defaults={}
        do local state=88
            for _,name in ipairs(names) do defaults[name]=function() return state end end
        end
        _ownership_runs=0;_editor_class={K={},L={}}
        boss={card={New=function(name)
            local card={name=name,is_combat=true}
            for cb,fn in next,defaults do card[cb]=fn end
            return card
        end},move={New=function() return {is_combat=false} end}}
        serial=serial+1
        local sid="CardOwnershipSpec:"..serial
        local entry=must(Load.Capture(source,{name="Owners_Boss.lua"}))
        must(entry.reloadable,entry.reason);entry.file="Owners_Boss.lua"
        local f=must(Planning.Capture(entry,sid,_editor_class,defaults))
        f.defaults=defaults
        local c=f.capture
        local l={capture=c,snapshot=c.snapshot,entry=entry,session_id=sid,
            classes=_editor_class,content=bytes or source:gsub("return 10 end","return 20 end"),generation=1,fixture=f}
        f.refresh=function() return l end
        local d=must(Planning.Discover(f,must(Source.Build(l.content)),l.generation))
        local p=must(Planning.Prepare(f,d,{mode="file",root_ids={keya},refresh=f.refresh}))
        eq(#p.dependencies.safe_roots,1,"real requested A root safe")
        eq(#p.dependencies.blocked_roots,0,"no blocked preparation hides a refusal")
        return p,c,l
    end
    local function forbid()
        debug.setupvalue=function() mutations=mutations+1;error("policy writes") end
        debug.upvaluejoin=function() mutations=mutations+1;error("policy joins") end
        rawset(_G,"jit",{flush=function() mutations=mutations+1;error("policy flushes") end})
    end
    local function isolated_commit(checks,raw_write)
        local path="SpellHotReload/Apply/FileCommit.lua"
        local text=opts.sources and opts.sources[path]
        local chunk=text and assert(loadstring(text,"@candidate/"..path))
            or assert(loadfile(opts.module_path or "THDiMS/game/plugin/SpellHotReload/"..path))
        setfenv(chunk,setmetatable({rawset=raw_write or rawset,require=function(name)
            if name=="SpellHotReload.Apply.CommitCheck" and checks then return checks end
            return require(name)
        end},{__index=_G}))
        return chunk()
    end
    local function controller(module,sid)
        local tx=must(module.New(sid));controllers[#controllers+1]=tx;return tx
    end
    local function unchanged(p,c,l,base,a,b,label)
        eq(c.snapshot,base,label.." actual snapshot retained")
        eq(l.classes.K.cards[2].frame,a,label.." A frame retained")
        eq(l.classes.K.cards[3].frame,b,label.." B frame retained")
        eq(_ownership_runs,1,label.." no miniature source replay")
    end
    local ok,problem=pcall(function()
        must(Anchor.Supported(Compose.Capability(debug)))
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
        eq(mutations,0,"first-load metadata policy pure")
        local p,capture,live=real_fixture()
        local base=group(capture,Card).state
        local evidence=select(2,Files.GetAdapterRecords(capture,Card)).evidence
        local location=fragment(p,Card).card_runtime.file_location
        eq(Target.CheckFileDiscovery(location,capture,live),true,"all captured classes and placeholders checked")
        local cases={
            {"registry",function(c,l) l.classes={} end,"first-load class ownership required"},
            {"ownership sparse",function(c,l,s,e) e.ownership[1]=nil end,"first-load class ownership required"},
            {"units metatable",function(c,l,s) setmetatable(s.units,getmetatable(hostile)) end,"actual Card contribution required"},
            {"class replaced",function(c,l) l.classes.K={} end,"first-load class/list ownership changed"},
            {"list replaced",function(c,l) l.classes.K.cards={} end,"first-load class/list ownership changed"},
            {"owner duplicate",function(c,l,s,e) e.ownership[2]=e.ownership[1] end,"first-load class/list ownership changed"},
            {"list sparse",function(c,l) l.classes.K.cards[1]=nil end,"first-load class/list ownership changed"},
            {"placeholder replaced",function(c,l) l.classes.K.cards[1]={} end,"first-load slot ownership changed"},
            {"unselected replaced",function(c,l) l.classes.K.cards[3]={is_combat=true} end,"first-load slot ownership changed"},
            {"cross-class sharing",function(c,l,s,e)
                l.classes.L.cards[1]=l.classes.K.cards[2];e.ownership[2].slots[1]=l.classes.K.cards[2]
            end,"first-load slot ownership changed"},
        }
        for _,case in ipairs(cases) do
            p,capture,live=real_fixture();base=group(capture,Card).state
            evidence=select(2,Files.GetAdapterRecords(capture,Card)).evidence
            location=fragment(p,Card).card_runtime.file_location
            case[2](capture,live,base,evidence);forbid()
            local v,e=Target.CheckFileDiscovery(location,capture,live)
            refusal(v,e,"locate","ownership",case[3],nil,case[1])
        end
        for _,case in ipairs({
            {"unit slot",function(u) u.slot=1 end},
            {"unit card",function(u) u.card={} end},
            {"unit class",function(u) u.class_key="missing" end},
            {"combat changed",function(u) u.card.is_combat=false end},
        }) do
            p,capture,live=real_fixture();base=group(capture,Card).state
            location=fragment(p,Card).card_runtime.file_location
            case[2](base.units[keya]);forbid()
            local v,e=Target.CheckFileDiscovery(location,capture,live)
            refusal(v,e,"locate","ownership","published unit no longer owns its first-load combat slot",nil,case[1])
        end

        -- Every one of Card's seven callback positions is an actual raw
        -- permission. Changing one selected callback never installs another.
        for _,name in ipairs(names) do
            local bytes
            if name=="init" then bytes=source:gsub("return helper%(%) end","return 20 end",1)
            elseif name=="frame" then bytes=source:gsub("return 10 end","return 20 end",1)
            else
                bytes=source:gsub("function _tmp_sc:frame%(%) return 10 end",
                    "function _tmp_sc:frame() return 10 end\nfunction _tmp_sc:"..name.."() return 20 end",1)
            end
            p,capture,live=real_fixture(bytes)
            local f=fragment(p,Card);local action=f.raw_writes[1]
            eq(#f.raw_writes,1,"one exact callback action "..name)
            eq(action.target,live.classes.K.cards[2],"selected raw target "..name)
            eq(action.key,name,"selected raw key "..name)
            local sealed=must(seal(p));forbid()
            eq(Guard.Check(sealed,capture,live),true,"real callback policy "..name)
            eq(rawget(action.target,name),action.before,"callback policy never publishes "..name)
            eq(#f.read_set,21,"all seven callbacks of all three cards read")
        end
        p,capture,live=real_fixture()
        local sealed=must(seal(p))
        local function raw_read(s)
            for _,r in ipairs(s.read_set) do
                if r.target==live.classes.K.cards[2] and r.key=="frame" then return r end
            end
            error("missing genuine raw read")
        end
        for _,case in ipairs({
            {"foreign read",function(r) r.target={} end},
            {"non-callback read",function(r) r.key="name";r.value="A" end},
            {"changed read",function(r) r.value=function() end end},
            {"hostile read",function(r) r.target=hostile end},
        }) do
            p,capture,live=real_fixture();sealed=must(seal(p))
            case[2](raw_read(sealed));forbid()
            local v,e=Guard.Mechanical(sealed,capture,live)
            refusal(v,e,"commit","stale","raw read ownership or value changed",nil,case[1])
        end
        p,capture,live=real_fixture();sealed=must(seal(p))
        live.classes.K.cards[2].frame=nil
        local v,e=Guard.Check(sealed,capture,live)
        refusal(v,e,"inject","stale","published raw callback was externally replaced",keya,"external nil callback")
        -- A genuinely absent raw preimage is a neutral kernel case; see
        -- FileCommitSpec's actual absent-field first load. Never forge Card state.

        -- Semantic member identity and physical write permission are distinct.
        -- These corruptions use genuine complete fragments, not fake owners.
        for _,case in ipairs({
            {"unknown key",function(w) w.key="unknown" end},
            {"non-function",function(w) w.value=false end},
            {"hostile target",function(w) w.target=hostile end},
            {"wrong member",function(w,l) w.target=l.classes.K.cards[3];w.before=w.target.frame end},
            {"wrong preimage",function(w) w.before=function() end end},
        }) do
            p,capture,live=real_fixture()
            local f=fragment(p,Card);case[2](f.raw_writes[1],live)
            sealed=must(seal(p));forbid()
            v,e=Guard.Check(sealed,capture,live)
            refusal(v,e,"commit","ownership",nil,nil,"raw action "..case[1])
        end
        p,capture,live=real_fixture()
        fragment(p,Card).raw_writes[1].unit_ref={}
        v,e=seal(p)
        refusal(v,e,"commit","ownership","foreign write unit",nil,"Seal foreign action unit")
        for _,case in ipairs({
            {"publication key",function(pub) pub.key="unknown" end},
            {"publication value",function(pub) pub.value=false end},
            {"publication target",function(pub) pub.target=hostile end},
            {"publication member",function(pub) pub.unit_key="unknown" end},
            {"publication foreign",function(pub,l) pub.target=l.classes.K.cards[3] end},
            {"publication preimage",function(pub) pub.before=function() end end},
        }) do
            p,capture,live=real_fixture()
            case[2](fragment(p,Card).card_plan.publications[1],live)
            sealed=must(seal(p));forbid()
            v,e=Guard.Check(sealed,capture,live)
            refusal(v,e,"commit","ownership",nil,nil,case[1])
        end
        p,capture,live=real_fixture()
        local f=fragment(p,Card)
        f.raw_writes[2]=copy(f.raw_writes[1])
        f.card_plan.publications[2]=copy(f.card_plan.publications[1])
        sealed=must(seal(p));forbid()
        v,e=Guard.Check(sealed,capture,live)
        refusal(v,e,"commit","ownership","duplicate Card callback action",nil,"duplicate semantic publication")

        -- Native class authority must still reject an unknown physical slot
        -- independently of Card's finer selected-member map.
        p,capture,live=real_fixture();sealed=must(seal(p))
        sealed.journal[1].key="name";sealed.journal[1].before="A"
        v,e=Guard.Mechanical(sealed,capture,live)
        refusal(v,e,"commit","ownership","raw write authority or preimage changed",nil,"native raw permission")

        local joining=source:gsub("return state%+1","return state+2")
            :gsub("return helper%(%) end","return helper()+3 end",1)
        p,capture,live=real_fixture(joining);sealed=must(seal(p))
        check(#sealed.joins>0,"genuine selected new closures need joins")
        forbid();eq(Guard.Check(sealed,capture,live),true,"new selected join destinations accepted")
        for _,kind in ipairs({"anchor","default","helper","callback"}) do
            p,capture,live=real_fixture(joining);sealed=must(seal(p))
            local fn=kind=="anchor" and live.entry.anchor or
                (kind=="default" and live.fixture.defaults.frame or
                (kind=="helper" and must(Anchor.Get(live.entry,"helper")) or live.classes.K.cards[3].init))
            eq(sealed.forbidden[fn],true,"explicit forbidden identity "..kind)
            local proof=must(Compose.Plan(fn,live.entry))
            check(#proof.joins>0,"forbidden fixture has valid real capture slots")
            local destination=copy(proof.joins[1]);destination.owner=sealed.joins[1].owner
            destination.unit_ref=sealed.joins[1].unit_ref
            sealed.joins[1]=destination;forbid()
            v,e=Guard.Mechanical(sealed,capture,live)
            refusal(v,e,"commit","ownership","join destination is published or invalid",nil,"forbidden "..kind)
            -- Claiming the old function as an installed value cannot remove its
            -- exclusion; it is also rejected even if an earlier native check wins.
            sealed.installed[fn]={{owner=destination.owner,unit_ref=destination.unit_ref}}
            v,e=Guard.Mechanical(sealed,capture,live)
            eq(v,nil,"published destination cannot be claimed selected "..kind)
        end
        p,capture,live=real_fixture(joining);sealed=must(seal(p))
        local created=must(Compose.Create("function() return state end",nil,{"state"},{form="expression"}))
        local proof=must(Compose.Plan(created,live.entry));local fresh=copy(proof.joins[1])
        fresh.owner,fresh.unit_ref=sealed.joins[1].owner,sealed.joins[1].unit_ref
        sealed.joins[1]=fresh;forbid()
        v,e=Guard.Mechanical(sealed,capture,live)
        refusal(v,e,"commit","ownership","join destination is not selected for installation",nil,"unselected new closure")
        eq(mutations,0,"direct policies never write/join/flush")
        eq(traps,0,"direct policies never invoke hostile metatables")

        -- Real first-load capture consumes Card's actual policy and does not
        -- adopt any partial or refused owner group.
        p,capture,live=real_fixture()
        local marker={phase="capture",code="ownership",message="adapter capture refused",file=live.entry.file}
        local called=0
        Card.CaptureOwnership=function(m,classes,entry)
            called=called+1;eq(classes,live.classes,"capture registry delegation")
            eq(entry,live.entry,"capture entry delegation");eq(#m.units,2,"complete class match delegated")
            return nil,marker
        end
        local local_piece=must(Local.Capture(live.entry,live.session_id))
        v,e=Card.Capture(live.entry,live.session_id,local_piece,live.classes,live.fixture.defaults)
        eq(called,1,"real Card contribution consumes capture policy")
        eq(v,nil,"capture policy stops contribution");eq(e,marker,"capture policy error identity")

        for _,method in ipairs({"file","versions","reads","deletions"}) do
            p,capture,live=real_fixture();sealed=must(seal(p));called=0
            local card=fragment(p,Card);local before=capture.snapshot
            marker={phase="commit",code="ownership",message="adapter refused "..method,file=live.entry.file}
            local spy=function(...)
                called=called+1
                if method=="file" then
                    eq(select(1,...),card.card_runtime.file_location,"guard exact full location")
                    eq(select(2,...),capture,"guard exact capture");eq(select(3,...),live,"guard exact fresh live")
                elseif method=="versions" then
                    eq(select(1,...),card.card_plan,"guard exact Card plan")
                    eq(select(2,...),live.classes,"guard exact registry")
                elseif method=="reads" then eq(select(1,...),group(capture,Card).state,"guard actual callback read state")
                else
                    eq(select(1,...),card.card_plan,"guard exact deletion plan")
                    eq(select(2,...),capture,"guard deletion capture")
                    eq(select(3,...),live,"guard deletion live")
                    eq(select(4,...),card.card_view.discovery,"guard original discovery")
                end
                return nil,marker
            end
            if method=="file" then Target.CheckFileDiscovery=spy
            elseif method=="versions" then Cards.Guard=spy
            elseif method=="reads" then Cards.Reads=spy
            else Reconcile.CheckPublications=spy end
            v,e=Guard.Check(sealed,capture,live)
            eq(called,1,"real owner consumes "..method)
            eq(v,nil,"owner policy stops preflight");eq(e,marker,"direct Guard preserves policy error")
            eq(capture.snapshot,before,"guard keeps actual publication")
            eq(_ownership_runs,1,"guard no miniature replay")
        end

        -- The same-class wrong-member input must fail in the REAL registration
        -- path before flush/Consume, not merely in an isolated Mechanical call.
        p,capture,live=real_fixture()
        local before=capture.snapshot
        local old_a,old_b=live.classes.K.cards[2].frame,live.classes.K.cards[3].frame
        f=fragment(p,Card);f.raw_writes[1].target=live.classes.K.cards[3]
        f.raw_writes[1].before=live.classes.K.cards[3].frame
        local raw_count,flushes=0,0
        local tx=controller(isolated_commit(nil,function(t,k,value)
            raw_count=raw_count+1;return rawset(t,k,value)
        end),live.session_id)
        rawset(_G,"jit",{flush=function() flushes=flushes+1 end})
        local receipt,err=Planning.Publish(live.fixture,p,tx)
        refusal(receipt,err,"commit","ownership","Card callback publication action changed",nil,"registered wrong-member action")
        unchanged(p,capture,live,before,old_a,old_b,"wrong-member")
        eq(flushes,0,"wrong-member refused before cache invalidation")
        eq(raw_count,0,"wrong-member no native raw writes")
        eq(tx:Poisoned(),false,"wrong-member preflight not poison")

        p,capture,live=real_fixture();called=0
        before=capture.snapshot;old_a,old_b=live.classes.K.cards[2].frame,live.classes.K.cards[3].frame
        local checks=copy(Guard)
        marker={phase="commit",code="ownership",message="native authority refused",file=live.entry.file}
        checks.Mechanical=function(s,c,l)
            called=called+1;check(s.operation~=p.operation,"kernel checks sealed operation")
            check(s.fragments[2]~=fragment(p,Card),"kernel checks sealed owner fragment")
            eq(s.base_snapshot,before,"kernel actual common base")
            return nil,marker
        end
        tx=controller(isolated_commit(checks),live.session_id)
        checks.Mechanical=Guard.Mechanical
        flushes=0;rawset(_G,"jit",{flush=function() flushes=flushes+1 end})
        eq(tx:Run(function(token)
            v,e=tx:Commit(token,p.operation,fragments(p),live,live.fixture.refresh)
            refusal(v,e,"commit","ownership",marker.message,nil,"kernel mechanical policy")
            eq(tx:Check(token),true,"preflight refusal retains token")
        end),true,"policy refusal scope returns")
        eq(called,1,"kernel consumes captured Mechanical policy")
        eq(flushes,0,"mechanical policy refusal before flush")
        unchanged(p,capture,live,before,old_a,old_b,"mechanical refusal")
        eq(tx:Poisoned(),false,"preflight refusal not poison")
        eq(traps,0,"all hostile metatables untouched")
    end)
    restore()
    for _,tx in ipairs(controllers) do tx:Release() end
    for _,key in ipairs(keys) do rawset(_G,key,globals[key]) end
    if not ok then failed=failed+1;failures[#failures+1]="unexpected: "..(type(problem)=="string" and problem or "non-string error") end
    print(string.format("CardOwnershipSpec: %d passed / %d failed",passed,failed))
    for _,failure in ipairs(failures) do print("  FAIL: "..failure) end
    return {passed=passed,failed=failed,failures=failures}
end
return M
