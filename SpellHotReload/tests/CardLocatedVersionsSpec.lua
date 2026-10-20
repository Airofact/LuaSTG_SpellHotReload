-- Real full-file/Current locations feed private Card versions and ONE transaction.
-- Miniature first-load fixtures alone execute. Every preparation discovers anew.
local M={}
local serial=0
function M.run()
    local Cards=require("SpellHotReload.Adapters.Card.CardVersions")
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local Local=require("SpellHotReload.Adapters.Local.Local")
    local Files=require("SpellHotReload.Pipeline.FileVersions")
    local Target=require("SpellHotReload.Adapters.Card.CardTarget")
    local Load=require("SpellHotReload.Load.AnchorLoad")
    local Source=require("SpellHotReload.Source.FileAnalysis")
    local Planning=require("SpellHotReload.tests.PlanningFixture")
    local FileApply=require("SpellHotReload.Apply.FileApply")
    local Guard=require("SpellHotReload.Apply.CommitCheck")
    local Dependencies=require("SpellHotReload.Pipeline.Dependencies")
    local Tx=require("SpellHotReload.Apply.FileCommit")
    local Anchor=require("SpellHotReload.Load.Anchor")
    local Compose=require("SpellHotReload.Source.Compose")
    local passed,failed,failures=0,0,{}
    local controllers={}
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
    local function layout_snapshot(value)
        if type(value)~="table" then return value end
        local result={}
        for key,item in next,value do result[key]=layout_snapshot(item) end
        return result
    end
    local function layout_matches(actual,expected,separate)
        if type(actual)~="table" or type(expected)~="table" then return rawequal(actual,expected) end
        if separate and rawequal(actual,expected) then return false end
        for key,value in next,expected do
            if not layout_matches(rawget(actual,key),value,separate) then return false end
        end
        for key in next,actual do if rawget(expected,key)==nil then return false end end
        return true
    end
    local function group(snapshot,owner)
        for _,g in ipairs(snapshot.owners) do if g.owner==owner then return g end end
        error("missing actual owner")
    end
    local function state(snapshot,owner) return group(snapshot,owner).state end
    local function view(d,owner)
        for _,g in ipairs(d.reconciliation.groups) do if g.owner==owner then return g.view end end
        error("missing real reconciliation")
    end
    local function fragment(p,owner)
        for _,record in ipairs(p.entries) do if record.owner==owner then return record.fragment end end
        error("missing owner preparation")
    end
    local function seal(p)
        local fragments={};for _,r in ipairs(p.entries) do fragments[#fragments+1]=r.fragment end
        return must(Guard.Seal(p.operation,fragments))
    end
    local function describe(p,sealed)
        sealed=sealed or seal(p)
        local impact=must(Dependencies.PublicationImpact(sealed.proposed_snapshot,sealed.owner_deltas))
        local description=must(Card.Describe(fragment(p,Card),{operation=p.operation,
            snapshot=p.operation.base_snapshot,dependencies=p.dependencies,impact=impact}))
        local rows={};for _,row in ipairs(description.cards) do rows[row.key]=row end
        return description,rows
    end
    local function pending(description)
        local keys={};for _,row in ipairs(description.cards) do if row.pending then keys[#keys+1]=row.key end end
        return keys
    end
    local function observed(snapshot,key)
        local out={};for _,r in ipairs(must(Cards.Observations(snapshot,group(snapshot,Card),key))) do out[r.name]=r.version end
        return out
    end
    local callbacks={"before","init","frame","render","beforedel","del","after"}
    local defaults={};for _,n in ipairs(callbacks) do defaults[n]=function() return "default" end end
    local globals={"boss","_editor_class","_tmp_sc","LOCATED_EFFECT","jit"}
    local saved={};for _,n in ipairs(globals) do saved[n]=rawget(_G,n) end
    local real_join,real_set=debug.upvaluejoin,debug.setupvalue
    local effects=0
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
        local classes={K={},L={}};_G._editor_class=classes
        _G.LOCATED_EFFECT=function() effects=effects+1 end
        _G.boss={card={New=function(label)
            local card={name=label,is_combat=true}
            for _,n in ipairs(callbacks) do card[n]=defaults[n] end
            return card
        end},move={New=function() return {is_combat=false} end}}
        local bytes=source(labels,move)
        local entry=must(Load.Capture(bytes,{name="Located_Boss.lua"}))
        must(entry.reloadable,entry.reason);entry.file="Located_Boss.lua"
        serial=serial+1
        local f=must(Planning.Capture(entry,"CardLocatedVersionsSpec:"..serial,classes,defaults))
        f.classes,f.slot,f.mode,f.content,f.generation=classes,slot,move and "debug" or "practice",bytes,0
        f.include_previous=false
        f.binding=function()
            local slots=classes.K.cards;local at=f.slot
            local names={};for i,card in ipairs(slots) do names[i]=card.name or "" end
            return {class_key="K",slot=at,card=slots[at],name=slots[at].name,names=names,
                mode=f.mode,include_previous=f.include_previous}
        end
        f.refresh=function()
            local live={capture=f.capture,snapshot=f.capture.snapshot,entry=f.entry,classes=classes,
                session_id=f.session,content=f.content,generation=f.generation}
            if not f.no_binding then live.binding=f.binding() end
            return live
        end
        return f
    end
    -- Input and lifecycle reads only; no compatibility report/Select/Next wrapper.
    local function input(f,bytes,at,mode,ids)
        f.content,f.slot,f.generation=bytes,at or f.slot,f.generation+1
        local facts=must(Source.Build(bytes))
        local d=must(Planning.Discover(f,facts,f.generation))
        local op=must(Planning.Operation(f,d,{mode=mode or "current",root_ids=ids,refresh=f.refresh}))
        return {discovery=d,operation=op,refresh=f.refresh}
    end
    local function prepare(f,bytes,at,mode,ids,raw)
        local x=input(f,bytes,at,mode,ids)
        local p,report
        if raw then
            p,report=f.driver:PrepareDiscovery(x.discovery,x.operation)
            if p then report=must(FileApply.Collect(p)) end
        else p,report=FileApply.Prepare(f.driver,x.discovery,x.operation) end
        if not p then return nil,report end
        if not raw then
            eq(#p.dependencies.safe_roots,1,"Current preparation has one safe root")
            eq(#p.dependencies.blocked_roots,0,"Current preparation has no blocked root")
        end
        x.report=report;return p,x
    end
    local function publish(f,p)
        if not f.tx then f.tx=must(Tx.New(f.session));controllers[#controllers+1]=f.tx end
        return Planning.Publish(f,p,f.tx)
    end
    local function changed_raw(card,key,value,body)
        local before=rawget(card,key);rawset(card,key,value)
        local ok,reason=pcall(body)
        rawset(card,key,before)
        must(ok,reason)
    end
    local function index(fn,wanted)
        for i=1,100 do local name=debug.getupvalue(fn,i);if name==wanted then return i end end
        error("fixture capture absent")
    end
    local ok,problem=pcall(function()
        must(Anchor.Supported(Compose.Capability(debug))) -- Real LuaJIT, no capability shim.
        local f=fixture({"A","B","C"},3,true)
        local base=f.capture.snapshot;local old=state(base,Card)
        local loaded_layout=layout_snapshot(old.layout)
        local bytes=source({"B"},true,{helper=7,bumps={B=25},no_l=true,no_frame=true,state=900})
        local joins,writes,flushes=0,0,0
        debug.upvaluejoin=function() joins=joins+1;error("premature join") end
        debug.setupvalue=function() writes=writes+1;error("premature write") end
        _G.jit={flush=function() flushes=flushes+1;error("premature flush") end}
        local before_effect=effects
        local p,x=prepare(f,bytes);must(p,x)
        local cf,lf=fragment(p,Card),fragment(p,Local)
        local runtime,plan=cf.card_runtime,cf.card_plan
        local location,locations=runtime.current_location,runtime.file_location
        local compared=runtime.version_view
        local a,b,c,side="card:1:K:2","card:1:K:3","card:1:K:4","card:1:L:1"
        eq(compared.locations,locations,"versions consume same explicit full-file proof")
        eq(location.discovery,x.discovery.snapshot,"Current retains complete discovery")
        eq(compared.source,x.discovery.source,"versions retain complete facts")
        eq(compared.source.content,bytes,"full raw candidate bytes")
        eq(locations.by_key[b].candidate_slot,2,"root uses shifted source descriptor")
        eq(locations.by_key[b].source_key,"card:K","source key is class coordinate")
        eq(compared.by_key[b].previous,old.units[b],"stable published identity")
        eq(compared.by_key[a].previous,old.units[a],"unmapped owner retained")
        eq(locations.by_key[a].status,"unmapped","cropping is not deletion")
        eq(locations.by_key[c].status,"unmapped","suffix owner not guessed")
        eq(locations.by_key[side].status,"source-absent","absent class explicit")
        list(locations.pending,a..","..c..","..side,"all old unmapped owners included")
        eq(#locations.unowned,0,"current candidate root claimed")
        list(plan.keys,b,"only Current root selected")
        eq(#p.dependencies.safe_roots,1,"one real safe root");eq(#p.dependencies.blocked_roots,0,"no hidden blocked root")
        eq(#lf.cell_writes,1,"only necessary shared definition")
        eq(lf.cell_writes[1].name,"helper","helper selected by public dependency")
        eq(#plan.publications,2,"init edit and optional frame deletion only")
        eq(plan.publications[1].target,old.units[b].card,"publish original live object")
        eq(plan.publications[2].key,"frame","exact optional deletion")
        eq(plan.publications[2].value,defaults.frame,"saved default restoration")
        eq(plan.publications[2].deletion.previous.definition,old.units[b].callbacks.frame,"exact old deletion version")
        eq(p.operation.file_proof.needs_top_level,true,"selected deletion obtains complete file proof")
        eq(FileApply.CheckDeletions(p.operation,plan,f.refresh()),true,"all-owner deletion proof valid")
        local sealed=seal(p);local proposed=sealed.proposed_snapshot;local next_card=state(proposed,Card)
        local description,rows=describe(p,sealed)
        list(pending(description),a..","..c..","..side,"unmapped owners remain pending")
        eq(#description.tombstones,1,"one absent-class diagnostic")
        eq(description.tombstones[1].key,side,"diagnostic retains old private key")
        eq(description.tombstones[1].definition_version,1,"diagnostic actual source version")
        eq(description.tombstones[1].action,"restart-required","no live object deletion")
        eq(locations.by_key[side].target.unit,old.units[side],"absent source retains actual owner")
        eq(#description.pending_sources,0,"no unowned sources")
        local affected={};for _,row in ipairs(description.cards) do if row.affected then affected[#affected+1]=row.key end end
        list(affected,a..","..b..","..c,"unmapped old consumers receive shared helper impact")
        list(next_card.order,table.concat(old.order,","),"no owners dropped")
        eq(layout_matches(old.layout,loaded_layout),true,"loaded layout content immutable")
        eq(layout_matches(next_card.layout,old.layout,true),true,"sealed loaded layout content retained and isolated")
        eq(proposed.loaded_source,base.loaded_source,"loaded bytes immutable")
        eq(next_card.units[b].slot,3,"restart slot never candidate index")
        eq(next_card.units[b].definition_version,2,"actual wrapper edit advances once")
        for _,key in ipairs({a,c,side}) do
            eq(next_card.units[key].definition_version,1,"unselected wrapper version retained")
            eq(next_card.units[key].callbacks.init.fn,old.units[key].callbacks.init.fn,"unselected callback retained")
        end
        eq(observed(proposed,a).helper,2,"unmapped shared observation advances")
        eq(observed(proposed,side).other,1,"independent observation unchanged")
        eq(f.capture.snapshot,base,"Seal never installs proposed version")
        eq(Anchor.Get(f.entry,"state"),4,"candidate initializer retained")
        eq(Guard.Check(sealed,f.capture,f.refresh()),true,"full proof supports read-only preflight")
        eq(effects,before_effect,"candidate initializer never executed")
        eq(joins,0,"no early joins");eq(writes,0,"no early cell writes");eq(flushes,0,"no early flush")
        -- Raw owner preparation does not authorize selected callback deletion.
        local raw,raw_x=prepare(f,bytes,nil,nil,nil,true);must(raw,raw_x)
        refuse(function() return Guard.Check(seal(raw),f.capture,f.refresh()) end,"ownership","deletion without full file proof")
        local unknown=bytes:gsub("LOCATED_EFFECT%(%)","LOCATED_EFFECT(1)")
        refuse(function() return prepare(f,unknown) end,"unsupported","selected deletion checks unknown full-file effect")
        eq(f.capture.snapshot,base,"failed proof never installs version")
        local blocked,bx=prepare(f,bytes,nil,"file",{a},true);must(blocked,bx)
        eq(#blocked.dependencies.safe_roots,0,"unmapped root cannot fall back")
        eq(#blocked.dependencies.blocked_roots,1,"exact unmapped root blocked")
        eq(blocked.dependencies.blocked_roots[1].reason.code,"ambiguous","unmapped root domain refusal")
        eq(#fragment(blocked,Card).raw_writes,0,"blocked root no callback write")
        eq(#fragment(blocked,Local).cell_writes,0,"blocked root no helper fallback")
        local empty,ex=prepare(f,bytes,nil,"file",{},true);must(empty,ex)
        local empty_description=describe(empty)
        list(pending(empty_description),a..","..b..","..c..","..side,"empty selection keeps all pending")
        eq(seal(empty).proposed_snapshot,base,"empty roots no revision")
        debug.upvaluejoin,debug.setupvalue,_G.jit=real_join,real_set,saved.jit
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
            f=fixture(case[1],case[2],case[3]);base=f.capture.snapshot;old=state(base,Card)
            p,x=prepare(f,source(case[4],case[5],{bom=case[8],helper=8}));must(p,x)
            cf=fragment(p,Card);runtime=cf.card_runtime;location=runtime.current_location
            local key="card:1:K:"..case[2]
            list(cf.card_plan.keys,key,case[7].." exact selected Current member")
            eq(#fragment(p,Local).cell_writes,1,case[7].." helper really prepared")
            eq(fragment(p,Local).cell_writes[1].name,"helper",case[7].." exact dependency")
            eq(location.candidate_slot,case[6],case[7].." candidate index")
            eq(p.operation.roots[1].root_id,key,case[7].." original private root")
            eq(location.target.slot,case[2],case[7].." original restart index")
            eq(location.discovery,x.discovery.snapshot,case[7].." complete discovery")
            eq(f.capture.snapshot,base,case[7].." no installation")
            eq(runtime.version_view.by_key[key].previous.card,old.units[key].card,case[7].." actual owner")
            eq(state(seal(p).proposed_snapshot,Card).units[key].slot,case[2],case[7].." stable proposed slot")
            if case[7]=="debug to full" then
                local desc=describe(p)
                eq(#runtime.file_location.unowned,2,"prefix and suffix unowned")
                eq(#desc.pending_sources,2,"both unowned sources pending")
                eq(desc.pending_sources[1].source_key,"card:K","pending source class coordinate")
                eq(desc.pending_sources[1].candidate_slot,2,"unowned candidate slot")
                eq(runtime.file_location.unowned[1].descriptor,x.discovery.snapshot.by_key["card:K"].unit.context.layout[2],"exact unowned source occurrence")
                eq(desc.pending_sources[1].action,"restart-required","unowned not publishable")
                eq(#cf.raw_writes,0,"helper-only does not publish Current wrapper")
                eq(#state(seal(p).proposed_snapshot,Card).order,#old.order,"no new owners seeded")
            end
        end
        -- Complete file location may prove an existing non-Current Side. Only
        -- the genuinely new Extra lacks an owner; neither is silently adopted.
        f=fixture({"A","B"},2,false);base=f.capture.snapshot;old=state(base,Card)
        bytes=source({"A","B"},false,{l={"Side","Extra"},helper=2})
        p,x=prepare(f,bytes);must(p,x);cf=fragment(p,Card)
        description,rows=describe(p)
        list(cf.card_plan.keys,"card:1:K:2","Side addition keeps exact Current member")
        eq(#fragment(p,Local).cell_writes,1,"Side addition Current helper really prepared")
        eq(fragment(p,Local).cell_writes[1].name,"helper","Side addition exact Current dependency")
        eq(cf.card_runtime.file_location.by_key[side].status,"located","Side independently proven from full layout")
        eq(cf.card_runtime.version_view.by_key[side].changed,false,"existing Side callback unchanged")
        eq(rows[side].selected,false,"non-Current Side not selected")
        eq(rows[side].pending,false,"proven unchanged Side not an identity gap")
        eq(#description.pending_sources,1,"only new Extra unowned")
        eq(description.pending_sources[1].source_key,"card:L","other candidate class retained")
        eq(description.pending_sources[1].candidate_slot,2,"Extra source occurrence retained")
        eq(#state(seal(p).proposed_snapshot,Card).order,#old.order,"Extra never seeded")
        changed_raw(old.units[side].card,"init",function() end,function()
            refuse(function() return prepare(f,bytes) end,"stale","non-Current raw callback validated")
        end)
        -- Missing-source callbacks and their shared cells are still checked.
        local absent_bytes=source({"A","B"},false,{helper=2,no_l=true})
        changed_raw(old.units[side].card,"init",function() end,function()
            refuse(function() return prepare(f,absent_bytes) end,"stale","absent source raw callback validated")
        end)
        local old_side=old.units[side].card.init
        local other=function() return 0 end;local function foreign() return other end
        real_join(old_side,index(old_side,"other"),foreign,index(foreign,"other"))
        local sharing_ok,sharing_problem=pcall(function()
            refuse(function() return prepare(f,absent_bytes) end,"stale","absent source callback sharing validated")
        end)
        real_join(old_side,index(old_side,"other"),f.entry.anchor,f.entry.slots.other)
        must(sharing_ok,sharing_problem)
        -- Fixed layouts retain sibling edits; a Current request cannot consume
        -- another private selector merely because both share one public unit.
        f=fixture({"A","B"},1,false);base=f.capture.snapshot;old=state(base,Card)
        bytes=source({"A","B"},false,{helper=3,bumps={A=15,B=25},other=200})
        p,x=prepare(f,bytes);must(p,x);cf=fragment(p,Card)
        local ka,kb="card:1:K:1","card:1:K:2"
        eq(cf.card_runtime.version_view.by_key[kb].changed,true,"mapped sibling edit visible")
        description,rows=describe(p)
        list(pending(description),kb,"mapped sibling edit stays pending")
        list(fragment(p,Local).local_view.version_view.changed,"helper,other","independent Local edits retained")
        eq(#fragment(p,Local).cell_writes,1,"other branch not selected")
        eq(fragment(p,Local).cell_writes[1].name,"helper","only current dependency prepared")
        changed_raw(old.units[kb].card,"init",function() end,function()
            refuse(function() return prepare(f,bytes) end,"stale","all unselected callbacks validated")
        end)
        local request=input(f,bytes)
        local sibling
        for _,root in ipairs(Card.Roots(view(request.discovery,Card))) do if root.root_id==kb then sibling=root end end
        request.operation.roots={must(sibling)}
        refuse(function() return FileApply.Prepare(f.driver,request.discovery,request.operation) end,"ownership","Current cannot consume sibling selector")
        -- New preparation after each negative operation; locations are never a
        -- reusable cache or independent permission to publish.
        p,x=prepare(f,bytes);must(p,x);cf=fragment(p,Card)
        location=cf.card_runtime.current_location;sealed=seal(p)
        local bad_location=copy(location);bad_location.candidate_slot=location.candidate_slot+1
        refuse(function() local live=f.refresh();return Target.CheckDiscovery(bad_location,live.binding,f.capture,live) end,"stale","tampered source mapping")
        local wrong_live=f.refresh();wrong_live.snapshot=copy(base)
        refuse(function() return Guard.Check(sealed,f.capture,wrong_live) end,"stale","wrong publication snapshot")
        f.content=bytes.."\n"
        refuse(function() return Guard.Check(sealed,f.capture,f.refresh()) end,"stale","fresh candidate bytes")
        f.content=bytes;f.include_previous=true
        refuse(function() return Guard.Check(sealed,f.capture,f.refresh()) end,"stale","commit restart context rechecked")
        f.include_previous=false;f.no_binding=true
        refuse(function() return Guard.Check(sealed,f.capture,f.refresh()) end,"unsupported","fresh binding required")
        f.no_binding=false
        eq(Guard.Check(sealed,f.capture,f.refresh()),true,"restored exact preflight valid")
        local saved_name=old.units[ka].card.name;old.units[ka].card.name="External"
        local name_ok,name_problem=pcall(function()
            refuse(function() return Guard.Check(sealed,f.capture,f.refresh()) end,"stale","commit live name changed")
        end)
        old.units[ka].card.name=saved_name;must(name_ok,name_problem)
        debug.upvaluejoin=nil
        local cap_ok,cap_problem=pcall(function()
            refuse(function() return Guard.Check(sealed,f.capture,f.refresh()) end,"capability","real shared capability revoked")
        end)
        debug.upvaluejoin=real_join;must(cap_ok,cap_problem)
        -- Same real neutral transaction for Local helper + selected Card writes.
        f=fixture({"A","B","C"},3,true);base=f.capture.snapshot;old=state(base,Card)
        bytes=source({"B"},true,{helper=7,bumps={B=25},no_l=true,no_frame=true})
        p,x=prepare(f,bytes);must(p,x)
        local original_a,original_b=old.units[a].card.init,old.units[b].card.init
        local receipt=must(publish(f,p))
        eq(receipt.changed,true,"real common transaction changed")
        eq(receipt.snapshot,f.capture.snapshot,"actual snapshot installed")
        eq(receipt.snapshot.revision,1,"one common transaction revision")
        eq(old.units[a].card.init,original_a,"unmapped wrapper not replaced")
        eq(old.units[b].card.init==original_b,false,"Current wrapper replaced")
        eq(old.units[a].card:init(1),22,"unmapped callback reads shared helper")
        eq(old.units[b].card:init(1),37,"shifted Current callback used")
        eq(old.units[b].card.frame,defaults.frame,"actual saved default restored")
        eq(old.units[a].card.frame(),4,"state unchanged")
        eq(Anchor.Get(f.entry,"state"),4,"Anchor state retained")
        p,x=prepare(f,bytes);must(p,x)
        eq(#fragment(p,Card).raw_writes,0,"repeat compares actual callback baseline")
        eq(#fragment(p,Local).cell_writes,0,"repeat compares actual helper baseline")
        list(pending(describe(p)),a..","..c..","..side,"repeat retains unmapped owners")
        local same_snapshot=f.capture.snapshot
        receipt=must(publish(f,p));eq(receipt.changed,false,"repeat no spurious revision")
        eq(f.capture.snapshot,same_snapshot,"repeat retains actual snapshot")
        bytes=source({"A","B","C"},true,{helper=7,bumps={A=15,B=25},no_frame=true})
        p,x=prepare(f,bytes,2);must(p,x);cf=fragment(p,Card)
        eq(cf.card_runtime.version_view.by_key[b].changed,false,"prior partial publication remembered")
        eq(cf.card_runtime.version_view.by_key[a].changed,true,"previous cropped wrapper edit available")
        description=describe(p);list(pending(description),c..","..side,"other full wrappers stay pending")
        receipt=must(publish(f,p));local actual=state(f.capture.snapshot,Card)
        eq(receipt.snapshot.revision,2,"second independent common transaction")
        eq(actual.units[a].definition_version,2,"second selected wrapper advances")
        eq(actual.units[b].definition_version,2,"first wrapper not readvanced")
        eq(old.units[a].card:init(1),27,"second card newly published")
        -- Observe persistent lifecycle scalar changes across final fresh reads.
        -- Rebuilding include_previous=false here would make this test vacuous.
        f=fixture({"A","B"},1,false);base=f.capture.snapshot;old=state(base,Card)
        p,x=prepare(f,source({"A","B"},false,{helper=9,bumps={A=15}}));must(p,x)
        local raw_before,helper_before=old.units[ka].card.init,Anchor.Get(f.entry,"helper")
        local post_flush=0;local old_jit=rawget(_G,"jit")
        _G.jit={flush=function() post_flush=post_flush+1;f.include_previous=true end}
        local flush_ok,flush_problem=pcall(function()
            refuse(function() return publish(f,p) end,"stale","post-flush Current proof")
        end)
        _G.jit=old_jit;must(flush_ok,flush_problem)
        eq(post_flush,1,"reached invalidation before final scalar refusal")
        eq(f.capture.snapshot,base,"post-flush no version install")
        eq(old.units[ka].card.init,raw_before,"post-flush no raw publication")
        eq(Anchor.Get(f.entry,"helper"),helper_before,"post-flush no cell write")
    end)
    debug.upvaluejoin,debug.setupvalue=real_join,real_set
    for _,n in ipairs(globals) do rawset(_G,n,saved[n]) end
    for _,controller in ipairs(controllers) do eq(controller:Release(),true,"common controller released") end
    if not ok then failed=failed+1;failures[#failures+1]="uncaught: "..(type(problem)=="string" and problem or "opaque failure") end
    print(string.format("CardLocatedVersionsSpec: %d passed / %d failed",passed,failed))
    for _,label in ipairs(failures) do print("  FAIL "..label) end
    return {passed=passed,failed=failed,failures=failures}
end
return M
