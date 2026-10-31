-- Genuine first-load contributions, complete adoption and Card-owned metadata.
-- Test-only miniature loads; no source replay, compatibility ledger or publication.
local M={}
function M.run()
    local Planning=require("SpellHotReload.tests.PlanningFixture")
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local Local=require("SpellHotReload.Adapters.Local.Local")
    local LocalVersions=require("SpellHotReload.Adapters.Local.LocalVersions")
    local Cards=require("SpellHotReload.Adapters.Card.CardVersions")
    local ClassAdapter=require("SpellHotReload.Adapters.Class.Class")
    local ClassFixture=require("SpellHotReload.tests.ClassFixture")
    local FileMatch=require("SpellHotReload.Pipeline.FileMatch")
    local Driver=require("SpellHotReload.Pipeline.Driver")
    local Files=require("SpellHotReload.Pipeline.FileVersions")
    local Load=require("SpellHotReload.Adapters.Class.ClassLoad")
    local Source=require("SpellHotReload.Source.FileAnalysis")
    local IR=require("SpellHotReload.Source.TopLevelIR")
    local Tree=require("SpellHotReload.Source.SyntaxTree")
    local Anchor=require("SpellHotReload.Load.Anchor")
    local Compose=require("SpellHotReload.Source.Compose")
    local passed,failed,failures=0,0,{}
    local function test(v,label)
        if v then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end
    end
    local function eq(a,b,label) test(rawequal(a,b),label) end
    local function must(v,e) assert(v,type(e)=="table" and rawget(e,"message") or e);return v end
    local function refusal(v,e,code,label)
        eq(v,nil,label.." refused");eq(type(e),"table",label.." structured")
        if type(e)=="table" then eq(e.code,code,label.." code");test(type(e.message)=="string",label.." safe message") end
    end
    local keys={"_seed_versions_runs","_seed_versions_api","jit","_BOSS_ESCAPE","_escape_x"}
    local environment
    local globals={};for _,key in ipairs(keys) do globals[key]=rawget(_G,key) end
    local get,set,join,id=debug.getupvalue,debug.setupvalue,debug.upvaluejoin,debug.upvalueid
    local slots={{Driver,"Discover","discover"},{Local,"Capture","local_capture"},
        {ClassAdapter,"Capture","class_capture"},{Card,"BuildContext","card_context"},
        {Card,"Match","card_match"},{Card,"CaptureOwnership","ownership"},
        {Cards,"Seed","seed"},{Files,"Capture","file_capture"},{Source,"Build","build"},
        {IR,"Analyze","analyze"},{Tree,"Parse","parse"},{Card,"Capture","card_capture"}}
    local original={};for _,slot in ipairs(slots) do original[slot[3]]=slot[1][slot[2]] end
    local traps,mutations=0,0
    local hostile=setmetatable({},{__index=function() traps=traps+1;error("hostile index") end,
        __tostring=function() traps=traps+1;error("hostile tostring") end})
    local names={"before","init","frame","render","beforedel","del","after"}
    local source=table.concat({
        "local state=4","local flag=false","local empty",
        "local function helper(n) return state+n end",
        "local function setter(v) state=v end",
        "local function reader() return state,flag,empty end",
        "local alias=helper",
        "_seed_versions_runs=_seed_versions_runs+1",
        "_seed_versions_api={set=setter,read=reader}",
        "_editor_class['K']=Class(boss)",
        "_editor_class['K'].cards={boss.move.New(0,0,1)}",
        "_tmp_sc=boss.card.New('A',1,2,3,100)",
        "function _tmp_sc:init(n) return helper(n) end",
        "function _tmp_sc:frame(n) return alias(n) end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
        "_tmp_sc=boss.card.New('B',1,2,3,100)",
        "function _tmp_sc:init(n) return helper(n)+100 end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
    },"\n")
    local function restore()
        for _,slot in ipairs(slots) do slot[1][slot[2]]=original[slot[3]] end
        debug.getupvalue,debug.setupvalue,debug.upvaluejoin,debug.upvalueid=get,set,join,id
        rawset(_G,"jit",globals.jit)
    end
    local function fixture(content)
        restore()
        if environment then environment:Restore() end
        environment=ClassFixture.Install()
        _seed_versions_runs=0
        local defaults={};for _,name in ipairs(names) do defaults[name]=function() end end
        boss.card={_default_card=defaults,New=function(label)
            local card={name=label,is_combat=true}
            for name,fn in next,defaults do card[name]=fn end
            return card
        end}
        boss.move={New=function() return {is_combat=false} end}
        local entry=must(Load.Capture(content or source,{name="SeedAdapter_Boss.lua"}))
        must(entry.reloadable,entry.reason);entry.file="SeedAdapter_Boss.lua"
        return entry,_editor_class,defaults
    end
    local function adopt(entry,session,classes,defaults)
        local f=must(Planning.Capture(entry,session,classes,defaults))
        environment:FinishLoad();return f
    end
    -- Syntax-only lookup uses the same completed three-owner discovery; no load.
    local function read(content,key)
        local facts,err=Source.Build(content);if not facts then return nil,err end
        local driver=Driver.New()
        for _,owner in ipairs({Local,ClassAdapter,Card}) do must(driver:RegisterDiscovery(owner)) end
        local discovery,why=driver:Discover("SeedAdapter_Boss.lua",facts,{session_id="seed:syntax",loaded_source=content})
        if not discovery then return nil,why end
        local match,problem=FileMatch.ForOwner(discovery.snapshot,Card,facts)
        if not match then return nil,problem end
        return match.by_class[key] and match.by_class[key].layout
    end
    local function metadata_traps()
        debug.setupvalue=function() mutations=mutations+1;error("capture writes") end
        debug.upvaluejoin=function() mutations=mutations+1;error("capture joins") end
        rawset(_G,"jit",{flush=function() mutations=mutations+1;error("capture flushes") end})
    end
    local function check_capture(capture,entry,classes,defaults,session,label)
        eq(Files.Validate(capture),true,label.." genuine common capture")
        local lp=must(Files.GetAdapterRecords(capture,Local));local cp,initial=Files.GetAdapterRecords(capture,Card);must(cp,initial)
        local class_group=must(Files.GetAdapterRecords(capture,ClassAdapter))
        local state=cp.state;local ownership=initial.evidence.ownership
        eq(capture.snapshot.entry,entry,label.." original entry");eq(capture.snapshot.anchor,entry.anchor,label.." original anchor")
        eq(capture.snapshot.session_id,session,label.." common session");eq(capture.snapshot.file,entry.file,label.." physical file")
        eq(capture.snapshot.loaded_source,entry.loaded_source,label.." original full bytes");eq(capture.snapshot.revision,0,label.." initial revision")
        eq(#capture.snapshot.owners,3,label.." all original Local/Class/Card owners")
        eq(initial.evidence.classes,classes,label.." registry identity")
        eq(initial.evidence.source,entry.source,label.." shared full source")
        eq(#ownership,1,label.." complete class ownership");eq(ownership[1].class,classes.K,label.." class identity")
        eq(ownership[1].list,classes.K.cards,label.." list identity");eq(#ownership[1].slots,3,label.." placeholder included")
        for slot,card in ipairs(classes.K.cards) do eq(ownership[1].slots[slot],card,label.." live slot "..slot) end
        eq(#state.order,2,label.." all explicit combat owners");eq(#cp.units,2,label.." one public unit per explicit card")
        eq(table.concat(state.order,","),"card:1:K:2,card:1:K:3",label.." combat source order")
        local refs={};local class_ref=class_group.state.by_key.K.unit_ref
        eq(state.class_providers.K,class_ref,label.." genuine Class provider")
        for _,key in ipairs(state.order) do
            local unit=state.units[key]
            eq(refs[unit.unit_ref],nil,label.." unique card unit ref "..key);refs[unit.unit_ref]=true
            eq(unit.class_ref,class_ref,label.." card retains actual Class dependency "..key)
            local edge=false
            for _,row in ipairs(capture.snapshot.graph) do
                if row.consumer==unit.unit_ref and row.provider==class_ref then edge=true end
            end
            eq(edge,true,label.." published Card-to-Class edge "..key)
            eq(unit.card,classes.K.cards[unit.slot],label.." original card "..key)
            eq(unit.definition_version,1,label.." initial card version "..key)
            for _,name in ipairs(names) do
                eq(unit.callbacks[name].fn,rawget(unit.card,name),label.." actual callback "..key..name)
                eq(unit.callbacks[name].definition_version,1,label.." callback version "..key..name)
            end
        end
        for _,name in ipairs({"helper","setter","reader"}) do
            eq(lp.state.by_name[name].fn,entry.map[name],label.." original trailer function "..name)
            eq(state.providers[name],lp.state.by_name[name].unit_ref,label.." canonical Local provider "..name)
        end
        eq(lp.state.by_name.alias.binding_kind,"state",label.." alias not a definition")
        for _,name in ipairs(names) do eq(state.defaults[name],defaults[name],label.." saved default "..name) end
        return lp,cp,initial
    end
    local module_keys={"SpellHotReload.Runtime.Plugin","SpellHotReload.Runtime.Watcher"}
    local modules={};for _,key in ipairs(module_keys) do modules[key]=package.loaded[key] end
    local plugins={}
    local ok,problem=pcall(function()
        must(Anchor.Supported(Compose.Capability(debug))) -- Real runtime capability; no presence-only shim.
        local entry,classes,defaults=fixture()
        local old_init,old_helper=classes.K.cards[2].init,entry.map.helper
        metadata_traps()
        local scans={Build=0,Analyze=0,Parse=0}
        for _,slot in ipairs({{Source,"Build"},{IR,"Analyze"},{Tree,"Parse"}}) do
            local name=slot[2]
            slot[1][name]=function() scans[name]=scans[name]+1;error("capture repeated full source work") end
        end
        local f=adopt(entry,"seed:session",classes,defaults);local direct=f.capture
        local lp,cp=check_capture(direct,entry,classes,defaults,"seed:session","first load")
        for _,name in ipairs({"Build","Analyze","Parse"}) do eq(scans[name],0,"contribution consumes existing full source "..name) end
        local saved_default=cp.state.defaults.after;defaults.after=function() end
        eq(cp.state.defaults.after,saved_default,"default snapshot retained");defaults.after=saved_default
        _seed_versions_api.set(nil);must(LocalVersions.Reads({base=lp.state}))
        eq(lp.state.by_name.helper.fn,old_helper,"nil state does not forge function identity")
        local state,flag,empty=_seed_versions_api.read()
        eq(state,nil,"nil state retained");eq(flag,false,"false state retained");eq(empty,nil,"empty state retained")
        _seed_versions_api.set(false);must(LocalVersions.Reads({base=lp.state}))
        eq(select(1,_seed_versions_api.read()),false,"false setter retained")
        eq(classes.K.cards[2].init,old_init,"no callback publication")
        eq(entry.map.helper,old_helper,"original trailer map unchanged")
        eq(_seed_versions_runs,1,"contributions do not replay source");eq(mutations,0,"no capture mutators")
        restore()
        -- A second genuine first load owns its own registry/defaults. Production
        -- adopts once; repeated Adopt of the same entry keeps the exact capture.
        package.loaded[module_keys[1]],package.loaded[module_keys[2]]=nil,{}
        local Plugin=require("SpellHotReload.Runtime.Plugin")
        local function new_plugin() local p=Plugin.New();plugins[#plugins+1]=p;return p end
        local p=new_plugin();local e2,c2,d2=fixture()
        local calls={0,0,0,0};local capture_methods={{Local,"Capture"},{ClassAdapter,"Capture"},{Card,"Capture"},{Files,"Capture"}}
        local capture_original={Local.Capture,ClassAdapter.Capture,Card.Capture,Files.Capture}
        for i,slot in ipairs(capture_methods) do
            local index=i
            slot[1][slot[2]]=function(...) calls[index]=calls[index]+1;return capture_original[index](...) end
        end
        local adopted,why=p:AdoptLoad(e2.file,e2)
        for i,slot in ipairs(capture_methods) do slot[1][slot[2]]=capture_original[i] end
        must(adopted,why);environment:FinishLoad();local captured=must(p:GetVersions(e2.file))
        check_capture(captured,e2,c2,d2,p._session_id,"production first load")
        test(captured~=direct and captured.snapshot~=direct.snapshot,"independent first loads have no module cache")
        eq(select(2,Files.GetAdapterRecords(direct,Card)).evidence.classes,classes,"earlier registry not replaced")
        eq(must(Files.GetAdapterRecords(direct,Card)).state.defaults.after,saved_default,"earlier saved defaults not replaced")
        local attempts=0
        Local.Capture=function() attempts=attempts+1;error("duplicate production capture") end
        local repeat_ok,repeat_err=pcall(function() must(p:AdoptLoad(e2.file,e2));p:_CaptureVersions(e2.file,e2) end)
        Local.Capture=original.local_capture
        must(repeat_ok,repeat_err);eq(attempts,0,"same entry not captured again")
        eq(p:GetVersions(e2.file),captured,"same entry keeps exact common capture")
        for i=1,4 do eq(calls[i],1,"complete adoption contributes once "..i) end
        eq(_seed_versions_runs,1,"independent load is executed once")
        -- Escape contributes opaque, non-selectable positions. Parsing and later
        -- discovery must not replay either its call or argument expressions.
        local escape_calls,argument_calls=0,0
        _escape_x=function() argument_calls=argument_calls+1;return -180 end
        _BOSS_ESCAPE=function(key)
            escape_calls=escape_calls+1;table.insert(_editor_class[key].cards,{is_combat=false})
            local deletion=boss.card.New("");deletion.init=function() end
            table.insert(_editor_class[key].cards,deletion)
        end
        local escaped=source.."\n_BOSS_ESCAPE('K',_escape_x(),300,60)\n_editor_class['L']=Class(boss)\n_editor_class['L'].cards={}"
            .."\n_tmp_sc=boss.card.New('Elsewhere',1,2,3,100)\nfunction _tmp_sc:init(n) return helper(n) end"
            .."\ntable.insert(_editor_class['L'].cards,_tmp_sc)"
        local layout=must(read(escaped,"K"))
        eq(#layout,5,"escape tail preserves both live positions")
        eq(layout[4].kind,"other","escape dialog opaque");eq(layout[5].kind,"other","escape deletion opaque")
        eq(next(layout[4].callbacks),nil,"escape dialog no reloadable callbacks")
        eq(next(layout[5].callbacks),nil,"escape deletion no reloadable callbacks")
        test(layout[4].constructor~=layout[5].constructor,"escape positions distinct signatures")
        eq(escape_calls,0,"parsing does not execute escape");eq(argument_calls,0,"parsing does not execute arguments")
        entry,classes,defaults=fixture(escaped)
        local ef=adopt(entry,"escape:session",classes,defaults)
        local cg,ci=Files.GetAdapterRecords(ef.capture,Card);must(cg,ci);local owned=ci.evidence.ownership
        eq(#owned,2,"all classes remain owned");eq(#owned[1].slots,5,"full live escape list captured")
        eq(owned[1].slots[4],classes.K.cards[4],"escape dialog identity retained")
        eq(owned[1].slots[5],classes.K.cards[5],"escape deletion identity retained")
        eq(#cg.state.order,3,"only explicit combat callbacks are roots");eq(#cg.units,3,"three explicit cards have distinct public units")
        local raw_targets={};for _,authority in ipairs(ci.authority.raws) do raw_targets[authority.target]=true end
        eq(raw_targets[classes.K.cards[4]],nil,"escape dialog has no raw setter authority")
        eq(raw_targets[classes.K.cards[5]],nil,"escape deletion has no raw setter authority")
        eq(escape_calls,1,"normal load executes escape once");eq(argument_calls,1,"normal load evaluates arguments once")
        local d=must(Planning.Discover(ef,entry.source,1))
        local refresh=function() return {capture=ef.capture,snapshot=ef.capture.snapshot,entry=entry,
            session_id=ef.session,content=escaped,generation=1,classes=classes} end
        local prepared,report,operation=Planning.Prepare(ef,d,{mode="file",refresh=refresh});must(prepared,report)
        eq(#prepared.dependencies.blocked_roots,0,"escape file leaves no blocked root")
        eq(#prepared.dependencies.safe_roots,#operation.roots,"all requested escape file roots remain usable")
        eq(#operation.roots,6,"three Local and three explicit combat roots requested")
        for _,record in ipairs(prepared.entries) do
            eq(#record.fragment.joins+#record.fragment.cell_writes+#record.fragment.raw_writes,0,"unchanged escape file has no installation actions")
        end
        eq(escape_calls,1,"real version comparison does not replay escape")
        eq(argument_calls,1,"real version comparison does not replay arguments")
        eq(#must(read(escaped.."\n_editor_class['K'].cards={_tmp_sc}","K")),1,"later rebuild drops escape placeholders")
        local changed=must(read(escaped:gsub(",300,60",",301,60"),"K"))
        test(changed[4].constructor~=layout[4].constructor,"escape argument drift retained")
        eq(#must(read(source.."\nfunction ignored() _BOSS_ESCAPE('K',1,2,3) end","K")),3,"nested escape not top-level registration")
        local value,reason=read(source.."\n_BOSS_ESCAPE(target,1,2,3)","K")
        eq(value,nil,"dynamic escape target rejected")
        eq(type(reason),"table","dynamic target structured diagnostic")
        eq(reason.phase,"match","escape rejection belongs to shared discovery")
        eq(reason.code,"unsupported","dynamic escape target support boundary")
        value=read(source.."\n_BOSS_ESCAPE('K',1,2)","K");eq(value,nil,"incomplete arguments rejected")
        value=read("local _BOSS_ESCAPE=function() end\n"..source.."\n_BOSS_ESCAPE('K',1,2,3)","K")
        eq(value,nil,"local escape shadowing rejected")
        eq(escape_calls,1,"all inspection non-executing");eq(argument_calls,1,"all argument inspection non-executing")
        entry,classes,defaults=fixture()
        local first=adopt(entry,"seed:session",classes,defaults)
        set(entry.anchor,entry.slots.helper,function() return 99 end)
        local v,e=Local.Capture(entry,"seed:session",first.initial_discovery.snapshot)
        refusal(v,e,"stale","external function setter not reseeded")
        test(entry.map.helper~=select(2,get(entry.anchor,entry.slots.helper)),"trailer is history not live values")
        entry,classes,defaults=fixture();first=adopt(entry,"seed:session",classes,defaults)
        entry.map.helper=function() end
        v,e=Local.Capture(entry,"seed:session",first.initial_discovery.snapshot);refusal(v,e,"stale","forged trailer identity")
        for _,case in ipairs({
            {function(x) x.reloadable=false end,"ownership","non-reloadable entry"},
            {function(x) x.missing=true end,"ownership","missing entry"},
            {function(x) x.class_load=nil end,"unsupported","missing Class observation","class",
                "normal Class construction observation unavailable; restart game"},
            {function(_,c) c.K.cards[4]={} end,"ownership","extra live slot"},
            {function(_,c) c.K.cards[3]=c.K.cards[2] end,"ownership","duplicate live card"},
        }) do
            entry,classes,defaults=fixture();case[1](entry,classes)
            v,e=Planning.Capture(entry,"seed:session",classes,defaults)
            local label="invalid first-load input: "..case[3]
            refusal(v,e,case[2],label)
            if case[4] then
                eq(e.phase,case[4],label.." phase")
                eq(e.message,case[5],label.." exact reason")
            end
        end
        entry,classes,defaults=fixture()
        local captured_pieces
        Files.Capture=function(e,session,pieces)
            captured_pieces=pieces;return original.file_capture(e,session,pieces)
        end
        first=adopt(entry,"seed:session",classes,defaults);Files.Capture=original.file_capture
        local snapshot=first.initial_discovery.snapshot
        v,e=Local.Capture(hostile,"seed:session",snapshot);refusal(v,e,"ownership","hostile Local entry")
        -- Retain the real contribution arguments, including capture authority;
        -- a published Owner group deliberately omits that first-load metadata.
        eq(#captured_pieces,3,"original capture received complete contribution objects")
        local local_piece,class_piece=captured_pieces[1],captured_pieces[2]
        eq(local_piece.owner,Local,"retained original Local contribution")
        eq(class_piece.owner,ClassAdapter,"retained original Class contribution")
        eq(local_piece.state,must(Files.GetAdapterRecords(first.capture,Local)).state,"contribution belongs to actual Local capture")
        eq(class_piece.state,must(Files.GetAdapterRecords(first.capture,ClassAdapter)).state,"contribution belongs to actual Class capture")
        for _,inputs in ipairs({
            {hostile,"seed:session",local_piece,class_piece,classes,defaults,snapshot},
            {entry,"seed:session",local_piece,class_piece,hostile,defaults,snapshot},
            {entry,"seed:session",local_piece,class_piece,classes,hostile,snapshot},
        }) do
            v,e=Card.Capture(unpack(inputs));refusal(v,e,"ownership","hostile Card capture input")
        end
        -- A missing Class provider cannot seed a Card contribution. A foreign
        -- genuine provider cannot enter this file's complete publication graph.
        local first_entry,first_classes,first_defaults=entry,classes,defaults
        local first_snapshot=first.capture.snapshot
        local first_match=must(FileMatch.ForOwner(snapshot,Card,first_entry.source))
        local combat,ownership=Card.CaptureOwnership(first_match,first_classes,first_entry);must(combat,ownership)
        local function first_provider(binding) return Local.CapturedProvider(local_piece,binding) end
        v,e=Cards.Seed(Card,first_entry,"seed:session",first_match,combat,ownership,first_classes,first_defaults,
            first_provider,function() return nil end)
        refusal(v,e,"ownership","missing Class provider cannot seed Card")
        local foreign_entry,foreign_classes,foreign_defaults=fixture()
        local foreign=adopt(foreign_entry,"seed:foreign",foreign_classes,foreign_defaults)
        local foreign_class=must(Files.GetAdapterRecords(foreign.capture,ClassAdapter))
        test(foreign_class.state.by_key.K.unit_ref~=class_piece.state.by_key.K.unit_ref,
            "independent first loads have distinct actual Class refs")
        local foreign_card=must(Cards.Seed(Card,first_entry,"seed:session",first_match,combat,ownership,
            first_classes,first_defaults,first_provider,
            function(key) return ClassAdapter.CapturedProvider(foreign_class,key) end))
        v,e=Files.Capture(first_entry,"seed:session",{local_piece,class_piece,foreign_card})
        refusal(v,e,"ownership","foreign Class edge cannot enter original file capture")
        eq(e.message,"invalid effective unit edge","foreign provider fails at complete graph boundary")
        eq(first.capture.snapshot,first_snapshot,"refused provider cannot replace actual publication")
        eq(foreign.capture.snapshot.revision,0,"foreign original capture remains unchanged")

        -- Full shared discovery precedes all genuine Local/Class/Card capture.
        -- Context refusal is translated by the discovery boundary; contribution
        -- refusals retain their identity. Neither may adopt a partial file.
        for stop=0,6 do
            entry,classes,defaults=fixture()
            local adopted_entry,adopted_classes,adopted_defaults=entry,classes,defaults
            local owned_plugin=new_plugin();local marker={phase="capture",code="ownership",message="fixture contribution refusal"}
            local log={};local local_result,class_result,matched,combat,ownership,card_result,file_result,shared_snapshot
            local function step(index) log[#log+1]=index;return stop~=index end
            Card.BuildContext=function(facts,units,...)
                eq(facts,adopted_entry.source,"Card context uses original complete source")
                eq(#units,2,"Card context receives both matched single-card units")
                if not step(1) then return nil,marker end
                matched=must(original.card_context(facts,units,...));return matched
            end
            Local.Capture=function(e,session,snapshot)
                eq(e,adopted_entry,"Local original entry");eq(session,owned_plugin._session_id,"Local explicit session")
                eq(snapshot.common.source,e.source,"Local receives complete shared discovery")
                eq(must(FileMatch.ForOwner(snapshot,Card,e.source)),matched,"Local and Card share one discovery")
                shared_snapshot=snapshot
                if not step(2) then return nil,marker end
                local_result=must(original.local_capture(e,session,snapshot));return local_result
            end
            ClassAdapter.Capture=function(e,session,locals,snapshot)
                eq(e,adopted_entry,"Class original entry");eq(session,owned_plugin._session_id,"Class explicit session")
                eq(locals,local_result,"Class consumes original Local contribution")
                eq(snapshot,shared_snapshot,"Class uses the same shared discovery")
                if not step(3) then return nil,marker end
                class_result=must(original.class_capture(e,session,locals,snapshot));return class_result
            end
            Card.CaptureOwnership=function(m,classes,e)
                eq(m,matched,"ownership receives completed Card context");eq(classes,adopted_classes,"ownership explicit registry")
                eq(e,adopted_entry,"ownership original entry")
                if not step(4) then return nil,marker end
                combat,ownership=original.ownership(m,classes,e);must(combat,ownership);return combat,ownership
            end
            Cards.Seed=function(owner,e,session,m,owners,ownerships,classes,defaults,provider,class_provider)
                eq(owner,Card,"Card owns callback versions");eq(e,adopted_entry,"Card versions original entry")
                eq(session,owned_plugin._session_id,"Card versions explicit session")
                eq(m,matched,"Card versions same completed context");eq(owners,combat,"Card versions complete combat owners")
                eq(ownerships,ownership,"Card versions complete ownership");eq(classes,adopted_classes,"Card versions registry")
                eq(defaults,adopted_defaults,"Card versions saved defaults")
                eq(provider(Source.Declaration(e.source,"helper")),local_result.state.by_name.helper.unit_ref,"provider canonical Local ref")
                eq(class_provider("K"),class_result.state.by_key.K.unit_ref,"provider actual captured Class ref")
                if not step(5) then return nil,marker end
                card_result=must(original.seed(owner,e,session,m,owners,ownerships,classes,defaults,provider,class_provider));return card_result
            end
            Files.Capture=function(e,session,pieces)
                eq(e,adopted_entry,"File original entry");eq(session,owned_plugin._session_id,"File explicit session")
                eq(#pieces,3,"File complete three-owner contributions")
                eq(pieces[1],local_result,"File original Local piece");eq(pieces[2],class_result,"File original Class piece")
                eq(pieces[3],card_result,"File original Card piece")
                if not step(6) then return nil,marker end
                file_result=must(original.file_capture(e,session,pieces));return file_result
            end
            metadata_traps()
            local ran,adopted,why=pcall(owned_plugin.AdoptLoad,owned_plugin,adopted_entry.file,adopted_entry)
            restore();environment:FinishLoad()
            must(ran,adopted);must(adopted,why)
            local capture,err=owned_plugin:GetVersions(adopted_entry.file)
            local last=stop==0 and 6 or stop
            eq(#log,last,"refusal exact short-circuit "..stop)
            for i=1,last do eq(log[i],i,"real dependency order "..stop..":"..i) end
            if stop==0 then
                eq(capture,file_result,"complete common capture exact identity");eq(err,nil,"successful contribution verdict")
                check_capture(capture,adopted_entry,adopted_classes,adopted_defaults,owned_plugin._session_id,"all real seams")
            else
                eq(capture,nil,"no partial adoption "..stop)
                if stop==1 then
                    eq(err.phase,"match","context failure remains a discovery refusal")
                    eq(err.code,marker.code,"context refusal code preserved")
                    eq(err.message,marker.message,"context refusal detail preserved")
                    eq(err.file,adopted_entry.file,"context refusal file preserved")
                else eq(err,marker,"contribution refusal identity "..stop) end
            end
            local retries=0
            Driver.Discover=function() retries=retries+1;error("late shared discovery") end
            Local.Capture=function() retries=retries+1;error("late contribution") end
            local again,aerr=pcall(function()
                owned_plugin:_CaptureVersions(adopted_entry.file,adopted_entry)
                must(owned_plugin:AdoptLoad(adopted_entry.file,adopted_entry))
            end)
            restore();must(again,aerr)
            eq(retries,0,"success/failure verdict cannot be reconstructed late")
            local retained,retained_reason=owned_plugin:GetVersions(adopted_entry.file)
            eq(retained,capture,"original complete-or-absent capture retained")
            eq(retained_reason,err,"original refusal retained")
            eq(_seed_versions_runs,1,"fault case does not replay miniature source")
        end
        -- A real per-position Match failure must also stop before any capture.
        entry,classes,defaults=fixture();local refused_plugin=new_plugin()
        local match_calls,contributions=0,0
        Card.Match=function(cursor,common)
            match_calls=match_calls+1
            eq(common.source,entry.source,"Match refusal reads the original full Source")
            test(cursor:Peek()~=nil,"Match refusal occurs at a real syntax position")
            return nil,{code="unsupported",message="fixture single-card Match refusal"}
        end
        Local.Capture=function() contributions=contributions+1;error("capture after Match refusal") end
        must(refused_plugin:AdoptLoad(entry.file,entry));restore();environment:FinishLoad()
        local absent,reason=refused_plugin:GetVersions(entry.file)
        eq(absent,nil,"Match refusal adopts no owner")
        eq(reason.phase,"match","Match failure keeps discovery phase")
        eq(reason.code,"unsupported","Match failure keeps support diagnostic")
        eq(reason.message,"fixture single-card Match refusal","Match failure keeps actual detail")
        eq(match_calls,1,"first failing Match stops discovery")
        eq(contributions,0,"Match refusal cannot reach Local capture")
        Driver.Discover=function() error("late failed Match retry") end
        local retried,retry_error=pcall(function()
            refused_plugin:_CaptureVersions(entry.file,entry)
            must(refused_plugin:AdoptLoad(entry.file,entry))
        end)
        restore();must(retried,retry_error)
        eq(select(2,refused_plugin:GetVersions(entry.file)),reason,"Match refusal remains the original verdict")
        eq(mutations,0,"no first-load metadata mutators in any seam")
        eq(traps,0,"no hostile metamethod")
    end)
    restore()
    for _,p in ipairs(plugins) do
        local released,reason=p:Release("CardSeedVersionsSpec complete")
        test(released==true,"Plugin released: "..(type(reason)=="string" and reason or ""))
    end
    for _,key in ipairs(module_keys) do package.loaded[key]=modules[key] end
    if environment then environment:Restore() end
    for _,key in ipairs(keys) do rawset(_G,key,globals[key]) end
    if not ok then failed=failed+1;failures[#failures+1]="unexpected: "..(type(problem)=="string" and problem or "opaque error") end
    for _,label in ipairs(failures) do print("FAIL CardSeedVersionsSpec: "..label) end
    return {passed=passed,failed=failed,failures=failures}
end
return M
