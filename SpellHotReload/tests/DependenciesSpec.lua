-- Scheduler domain fixtures, not production Local/Card or engine evidence.
local M={}
function M.run()
    local Dependencies=require("SpellHotReload.Pipeline.Dependencies")
    local Files=require("SpellHotReload.Pipeline.FileVersions")
    local Load=require("SpellHotReload.Load.AnchorLoad")
    local passed=0
    local function eq(a,b,label) assert(a==b,label);passed=passed+1 end
    local function must(v,why) assert(v,type(why)=="table" and why.message or why);return v end
    local function contains(list,ref)
        for _,v in ipairs(list) do if v==ref then return true end end;return false
    end
    local function fixture()
        local entry=must(Load.Capture("local anchor_state=1",{name="Dependencies_Boss.lua"}))
        entry.file="Dependencies_Boss.lua"
        local owners,refs={{Id="cards"},{Id="locals"}},{}
        local contributions={}
        for i,owner in ipairs(owners) do
            local group={owner=owner,owner_id=owner.Id,state={},units={},records={},functions={},edges={},
                initial={},identity_objects={},authority={cells={},raws={},forbidden={}}}
            contributions[i]=group
            for n=1,3 do
                local ref={owner=owner,id=n};refs[#refs+1]=ref
                local definition={definition_version=1,unit_ref=ref}
                group.units[n]={unit_ref=ref,private_ref=definition}
                group.records[n]={key=owner.Id..":"..n,kind="fixture",definition=definition,definition_version=1}
            end
        end
        -- A retained consumer observes helper changes without being selected.
        contributions[1].edges={{consumer=refs[2],provider=refs[4]}}
        local capture=must(Files.Capture(entry,"DependenciesSpec",contributions))
        local op={file=entry.file,session_id="DependenciesSpec",entry=entry,anchor=entry.anchor,
            capture=capture,base_snapshot=capture.snapshot,source=entry.source,generation=2,mode="file"}
        local publication=must(Files.Publication(capture))
        local report={kind="SpellHotReload.Reconciliation",version=1,publication=publication,
            revision=0,file=entry.file,groups={},published=false}
        report.snapshot={common={source=entry.source},by_key={},reconciliation=report}
        local tokens={}
        for i,group in ipairs(capture.snapshot.owners) do
            local output={owner=group.owner,owner_id=group.owner_id,previous=publication.groups[i],view={},units={},exports={}}
            report.groups[i]=output
            for n,unit in ipairs(group.units) do
                local ref=unit.unit_ref
                tokens[ref]={{},{}}
                output.units[n]={unit_ref=ref,private_ref=unit.private_ref,status="old-only",
                    previous_records={group.records[n]}}
                output.exports[n]={unit_ref=ref,conditions=tokens[ref]}
            end
        end
        return {op=op,report=report,refs=refs,tokens=tokens}
    end
    local function root(id,ref,selector) return {root_id=id,unit_ref=ref,selector=selector or {}} end
    local function result(needs,affected) return {selection_ref={},needs=needs or {},affected=affected or {}} end
    local function need(request,f,ref,n,cause)
        return {root_id=request.root_id,provider_unit=ref,condition_ref=f.tokens[ref][n],cause_ref=cause or {}}
    end
    local function owner_unit(s,ref)
        for _,owner in ipairs(s.owners) do for _,u in ipairs(owner.units) do if u.unit_ref==ref then return u end end end
    end
    do
        local f=fixture();local r=f.refs;local calls,requests={},{}
        local selector={current_card="private"}
        local selection=must(Dependencies.Resolve(f.op,f.report,{root("A",r[1],selector)},function(owner,unit,request)
            local ref=request.unit_ref
            eq(owner,ref.owner,"owner receives only its own requested unit")
            eq(unit.unit_ref,ref,"request preserves original unit")
            calls[ref]=(calls[ref] or 0)+1;requests[ref]=request
            if ref==r[1] then return result({need(request,f,r[4],1)}) end
            if ref==r[4] then
                local needs={need(request,f,r[5],1)}
                if contains(request.conditions,f.tokens[r[4]][2]) then needs[#needs+1]=need(request,f,r[6],1) end
                return result(needs,{r[4]})
            end
            if ref==r[5] then return result({need(request,f,r[4],2),need(request,f,r[4],2)}) end
            return result()
        end))
        eq(selection.stable,true,"finite recursive demand reaches stability")
        eq(calls[r[4]],2,"provider reruns only for genuinely new cumulative condition")
        eq(#requests[r[4]].conditions,2,"provider receives full condition union")
        eq(calls[r[5]],1,"duplicate cycle demand does not rerun consumer")
        eq(calls[r[6]],1,"later cumulative condition discovers required provider")
        eq(#selection.safe_roots,1,"root is safe after full closure")
        eq(#selection.blocked_roots,0,"no invented cyclic block")
        eq(owner_unit(selection,r[6])~=nil,true,"transitive selected provider retained")
        eq(owner_unit(selection,r[2]),nil,"affected retained consumer is not selected")
        eq(contains(selection.affected,r[2]),true,"actual reverse edge observes helper change")
        eq(contains(selection.affected,r[1]),true,"proven candidate reverse edge observes helper change")
        eq(selection.candidate_scope,"requested","unprobed candidate graph not claimed complete")
        eq(requests[r[1]].selector,selector,"root selector is opaque and unchanged")
    end
    do
        local f=fixture();local r=f.refs;local calls={}
        local selection=must(Dependencies.Resolve(f.op,f.report,
            {root("safe",r[1],{branch="a"}),root("blocked",r[1],{branch="b"})},
            function(_,_,request)
                calls[request.root_id..":"..request.unit_ref.id]=(calls[request.root_id..":"..request.unit_ref.id] or 0)+1
                if request.unit_ref==r[1] then
                    local needs={need(request,f,r[4],1)}
                    if request.root_id=="blocked" then needs[#needs+1]=need(request,f,r[6],1) end
                    return result(needs)
                end
                if request.unit_ref==r[6] then
                    return {blocked={code="unsupported",message="only branch b is unsafe"},needs={},affected={}}
                end
                return result()
            end))
        eq(#selection.safe_roots,1,"independent root in same aggregate survives")
        eq(selection.safe_roots[1].root_id,"safe","safe provenance retained")
        eq(selection.blocked_roots[1].root_id,"blocked","provider block attributed to originating root")
        eq(#owner_unit(selection,r[1]).roots,1,"blocked card member not in aggregate selection")
        eq(#owner_unit(selection,r[4]).roots,1,"shared provider drops blocked root contribution")
        eq(owner_unit(selection,r[4]).roots[1].root_id,"safe","shared provider retains independent root")
        eq(owner_unit(selection,r[6]),nil,"blocked provider creates no final installation selection")
        eq(selection.owners[1].owner,r[1].owner,"owner order matches actual snapshot")
    end
    do
        local f=fixture();local r=f.refs;local calls=0
        local empty=must(Dependencies.Resolve(f.op,f.report,{},function() calls=calls+1;return result() end))
        eq(calls,0,"empty roots create no fake unit/hook")
        eq(#empty.owners,2,"empty contribution still retains all actual owners")
        eq(#empty.owners[1].units,0,"no fabricated Card selection")
        eq(#empty.owners[2].units,0,"no fabricated Local selection")
        local selected=must(Dependencies.Resolve(f.op,f.report,{root("old",r[4])},function(_,unit,request)
            eq(unit.candidate_entry,nil,"old-only does not require fake candidate key")
            if #request.conditions==0 then return result({need(request,f,r[4],1)}) end
            eq(request.selector~=nil,true,"root selector survives self demand refinement")
            return result()
        end))
        eq(#selected.safe_roots,1,"retained old-only proof can resolve without source occurrence")
    end
    do
        local mutations={
            function(f) f.report.groups[2].exports[1].conditions[1]={} end,
            function(f) f.report.groups[2].view={} end,
            function(f) f.report.groups[2].units[1].private_ref={} end,
            function(f) f.report.groups[2].units[1].status="changed-status" end,
            function(f) f.op.generation=nil end,
        }
        for i,mutate in ipairs(mutations) do
            local f=fixture()
            local value,why=Dependencies.Resolve(f.op,f.report,{root("unstable",f.refs[1])},function(_,_,q)
                if q.unit_ref==f.refs[1] then return result({need(q,f,f.refs[4],1)}) end
                mutate(f);return result()
            end)
            eq(value,nil,"changed finite domain/scope rejected "..i)
            eq(why.message,"owner domain changed during resolution","domain identity diagnostic "..i)
        end
    end
    do
        local f=fixture();local r=f.refs
        local node=f.op.source.analysis.statements[1].syntax
        local selection=must(Dependencies.Resolve(f.op,f.report,
            {root("drop",r[1]),root("keep-shared",r[2]),root("independent",r[3])},function(_,_,q)
                local value=result()
                if q.unit_ref==r[1] or q.unit_ref==r[2] then value.needs={need(q,f,r[4],1)} end
                if q.unit_ref==r[4] or q.unit_ref==r[3] then value.source_facts={{source=f.op.source,node=node}} end
                return value
            end))
        eq(#selection.source_facts,3,"each selected AST fact retains its root provenance")
        local block={code="unsupported",message="fixture business rule"}
        local reduced=must(Dependencies.Restrict(selection,{{root_id="drop",reason=block}}))
        eq(#reduced.safe_roots,2,"business restriction removes one root only")
        eq(reduced.blocked_roots[1].reason,block,"business refusal diagnostic retained")
        eq(owner_unit(reduced,r[1]),nil,"dropped consumer removed from final union")
        eq(#owner_unit(reduced,r[4]).roots,1,"shared provider keeps independent request")
        eq(owner_unit(reduced,r[4]).roots[1].root_id,"keep-shared","shared provider root attribution retained")
        eq(owner_unit(reduced,r[3])~=nil,true,"independent unit is not blocked")
        eq(#reduced.source_facts,2,"dropped root source facts removed")
        for _,fact in ipairs(reduced.source_facts) do
            eq(fact.root_id~="drop",true,"no rejected-root facts leak to prepare")
            eq(fact.source,f.op.source,"same complete source retained")
            eq(fact.node,node,"exact original syntax node retained")
        end
        eq(#selection.safe_roots,3,"restriction does not mutate original evidence")
        eq(#selection.source_facts,3,"restriction does not rewrite original facts")
        local empty=must(Dependencies.Restrict(reduced,{
            {root_id="keep-shared",reason=block},{root_id="independent",reason=block}}))
        eq(#empty.safe_roots,0,"all roots may be blocked")
        eq(#empty.owners,2,"all original owner shells survive pruning")
        eq(#empty.owners[1].units+#empty.owners[2].units,0,"no invented selection after full pruning")
        eq(#empty.source_facts,0,"no selected syntax after full pruning")
        local bad,why=Dependencies.Restrict(selection,{{root_id="foreign",reason=block}})
        eq(bad,nil,"restriction cannot add a foreign root");eq(why.code,"ownership","foreign restriction diagnostic")
    end
    do
        local makes={
            function(f) return {{source=fixture().op.source,node=f.op.source.analysis.statements[1].syntax}} end,
            function(f) return {{source=f.op.source,node={kind="function"}}} end,
            function(f) return {[2]={source=f.op.source,node=f.op.source.analysis.statements[1].syntax}} end,
            function() return setmetatable({},{__index=function() error("hostile facts") end}) end,
        }
        for i,make in ipairs(makes) do
            local f=fixture();local called=0
            local value,why=Dependencies.Resolve(f.op,f.report,{root("bad-fact",f.refs[1])},function()
                called=called+1;local out=result();out.source_facts=make(f);return out
            end)
            eq(value,nil,"foreign/malformed source fact refused "..i)
            eq(why.code,"ownership","source fact diagnostic "..i)
            eq(called,1,"foreign source facts cannot route another resolver "..i)
        end
    end
    -- Every malformed envelope rejects before the first owner hook.
    local bad_inputs={
        function(f,roots) roots[2]=root("ok",f.refs[2]) end,
        function(f,roots) roots[2]=root("foreign",{owner=f.refs[1].owner,id=1}) end,
        function(f,roots) roots[3]=root("sparse",f.refs[2]) end,
        function(f) f.report.groups[2].units[1].previous_records={} end,
        function(f) f.report.groups[2].units[2].unit_ref=f.refs[4] end,
        function(f) f.report.groups[1].exports[2].conditions=f.report.groups[1].exports[1].conditions end,
        function(f) f.report.groups[2].exports[2].unit_ref=f.refs[4] end,
        function(f) f.report.groups[2].reason="original adapter unavailable" end,
        function(f) f.report.groups[2].owner={Id="locals"} end,
        function(f) f.report.revision=1 end,
    }
    for i,damage in ipairs(bad_inputs) do
        local f=fixture();local roots={root("ok",f.refs[1])};local calls=0
        damage(f,roots)
        local value,why=Dependencies.Resolve(f.op,f.report,roots,function() calls=calls+1;return result() end)
        eq(value,nil,"malformed input rejected "..i);eq(why.code,"ownership","input diagnostic "..i)
        eq(calls,0,"all envelopes checked before hooks "..i)
    end
    local bad_results={
        function(f,q) return result({{root_id="other",provider_unit=f.refs[4],condition_ref=f.tokens[f.refs[4]][1],cause_ref={}}}) end,
        function(f,q) return result({{root_id=q.root_id,provider_unit=f.refs[4],condition_ref={},cause_ref={}}}) end,
        function(f,q) return result({{root_id=q.root_id,provider_unit=f.refs[4],condition_ref=f.tokens[f.refs[5]][1],cause_ref={}}}) end,
        function(f,q) return result({{root_id=q.root_id,provider_unit={owner=f.refs[4].owner,id=1},condition_ref=f.tokens[f.refs[4]][1],cause_ref={}}}) end,
        function(f,q) return result({{root_id=q.root_id,provider_unit=f.refs[4],condition_ref=f.tokens[f.refs[4]][1]}}) end,
        function(f) return result({},{{owner=f.refs[1].owner,id=1}}) end,
        function(f) return {blocked={code="unsupported",message="block"},selection_ref={},needs={},affected={}} end,
        function(f) return {needs={},affected={}} end,
        function(f) error("domain fault") end,
    }
    for i,make in ipairs(bad_results) do
        local f=fixture();local calls=0
        local value,why=Dependencies.Resolve(f.op,f.report,{root("ok",f.refs[1])},function(_,_,q)
            calls=calls+1;return make(f,q)
        end)
        eq(value,nil,"malformed result rejected "..i);eq(why.code,"ownership","result diagnostic "..i)
        eq(calls,1,"out-of-domain growth cannot reach another resolver "..i)
    end
    do
        local f=fixture();local before=f.op.capture.snapshot
        local value,why=Dependencies.Resolve(f.op,f.report,{root("drift",f.refs[1])},function()
            local next_snapshot={};for k,v in next,before do next_snapshot[k]=v end
            next_snapshot.revision=1;f.op.capture.snapshot=next_snapshot;return result()
        end)
        f.op.capture.snapshot=before
        eq(value,nil,"publication drift during resolution is rejected")
        eq(why.code,"ownership","publication drift diagnostic")
        local refused={phase="inject",code="stale",message="actual read changed"}
        value,why=Dependencies.Resolve(f.op,f.report,{root("refuse",f.refs[1])},function() return nil,refused end)
        eq(value,nil,"global read failure is not a per-root safe block")
        eq(why,refused,"original refusal diagnostic retained")
    end
    do
        local f=fixture();local r=f.refs;local actual=f.op.capture.snapshot
        local final={};for k,v in pairs(actual) do final[k]=v end
        final.graph={{consumer=r[1],provider=r[4]},{consumer=r[2],provider=r[4]},
            {consumer=r[4],provider=r[5]},{consumer=r[5],provider=r[4]}}
        local deltas={{owner=actual.owners[1].owner,owner_id=actual.owners[1].owner_id,changed=false,unit_refs={}},
            {owner=actual.owners[2].owner,owner_id=actual.owners[2].owner_id,changed=true,unit_refs={r[4]}}}
        local impact=must(Dependencies.PublicationImpact(final,deltas))
        eq(impact.changed[r[4]],true,"final actual installation delta is the only changed seed")
        eq(impact.changed[r[1]],nil,"observed impact is not another installation")
        for _,n in ipairs({1,2,4,5}) do eq(impact.affected[r[n]],true,"final cyclic/effective graph impact "..n) end
        eq(impact.affected[r[3]],nil,"unrelated actual unit is unaffected")
        deltas[2]={owner=deltas[2].owner,owner_id=deltas[2].owner_id,changed=false,unit_refs={}}
        impact=must(Dependencies.PublicationImpact(final,deltas))
        eq(next(impact.affected),nil,"fully removed roots cannot leave display impact without writes")
        eq(next(impact.changed),nil,"no-op display has no changed units")
        deltas[2].changed=true;deltas[2].unit_refs={r[1]}
        local value,why=Dependencies.PublicationImpact(final,deltas)
        eq(value,nil,"foreign owner's changed unit refused");eq(why.code,"ownership","impact domain diagnostic")
        deltas[2].unit_refs={r[4],r[4]}
        eq(Dependencies.PublicationImpact(final,deltas),nil,"duplicate final changed unit refused")
        deltas[2].unit_refs={r[4]};final.graph={{consumer=r[2],provider={owner=r[4].owner,id=1}}}
        eq(Dependencies.PublicationImpact(final,deltas),nil,"same id cannot replace actual provider ref")
        eq(f.op.capture.snapshot,actual,"pure impact never installs proposed metadata")
    end
    print("DependenciesSpec: "..passed.." passed, 0 failed")
    return {passed=passed,failed=0}
end
return M
