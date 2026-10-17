local M={}
function M.run()
    local Driver=require("SpellHotReload.Pipeline.Driver")
    local R=require("SpellHotReload.Pipeline.Reconciliation")
    local Registry=require("SpellHotReload.Pipeline.NodeRegistry")
    local passed=0
    local function eq(a,b,label) assert(a==b,label);passed=passed+1 end
    local calls,mutations=0,0
    local function adapter(id)
        return {Id=id,ContractVersion=4,
            Match=function(a,c) return {units={},claims={},context={}} end,
            Reconcile=function(old,candidate,ctx)
                calls=calls+1
                eq(ctx.previous,old,"original group passed")
                eq(ctx.common,candidate.common,"shared complete candidate")
                local rows={}
                for _,record in ipairs(old.records) do
                    rows[#rows+1]={status="unresolved",previous=record,reason="not proven",
                        evidence={},dependencies={},conditions={"prove identity"}}
                end
                return rows
            end,
            Locate=function() mutations=mutations+1 end,
            Inject=function() mutations=mutations+1 end,
            Commit=function() mutations=mutations+1 end}
    end
    local original=adapter("a")
    local definition={definition_version=7}
    local record={key="published:not-a-discovery-key",kind="callback",definition=definition,definition_version=7}
    local group={owner=original,owner_id="a",state={},records={record}}
    local publication={kind="SpellHotReload.Publication",version=1,file="A.lua",session_id="S",
        revision=5,entry={},loaded_source="first load",groups={group}}
    local driver=Driver.New();assert(driver:RegisterDiscovery(original))
    local d=assert(driver:DiscoverPublished("A.lua","",publication,{candidate_generation=9}))
    eq(calls,1,"zero-match owner still reconciled")
    eq(#d.index.list,0,"zero candidate units")
    eq(#d.reconciliation.rows,1,"old-only record retained")
    local r=d.reconciliation.rows[1]
    eq(r.owner,original,"original owner reference")
    eq(r.result.previous,record,"original publication record")
    eq(r.result.previous.definition,definition,"last published definition reference")
    eq(r.result.previous.definition_version,7,"last definition version")
    eq(r.result.candidate,nil,"no fabricated candidate key")
    eq(d.reconciliation.published,false,"report has no publish authority")
    eq(driver:SelectDiscovery(d,{record.key}),nil,"old key cannot select candidate")
    local b,e,failed=driver:DiscoverPublished("A.lua","function (",publication)
    eq(b,nil,"parse failure is failure")
    eq(e.phase,"analyze","original source diagnostic")
    eq(calls,1,"parse failure never calls reconciliation hook")
    eq(failed.problem,"candidate analysis failed","analysis failure distinguished")
    eq(failed.source_error,e,"original source error retained")
    eq(failed.rows[1].result.status,"unresolved","parse failure retains old")
    eq(failed.rows[1].result.tombstone,nil,"parse failure never deletes")
    b,e,failed=driver:DiscoverPublished("A.lua",nil,publication)
    eq(b,nil,"missing read bytes are failure")
    eq(failed.problem,"candidate bytes unavailable","read failure distinguished")
    eq(failed.rows[1].result.previous,record,"read failure retains last record")
    original.Match=function() return nil,{code="ambiguous",message="broken layout"} end
    b,e,failed=driver:DiscoverPublished("A.lua","",publication)
    eq(b,nil,"Match failure is failure");eq(e.code,"ambiguous","Match diagnostic retained")
    eq(failed.problem,"candidate Match failed","Match failure distinguished")
    eq(failed.rows[1].result.status,"unresolved","Match failure never means absence")
    original.Match=function() return {units={},claims={},context={}} end
    local replacement=adapter("a");local other=Driver.New();assert(other:RegisterDiscovery(replacement))
    local replacement_seen
    replacement.Reconcile=function(old)
        replacement_seen=old
        eq(#old.records,0,"same-Id replacement never receives previous records")
        return {}
    end
    local replaced=assert(other:DiscoverPublished("A.lua","",publication)).reconciliation
    eq(replaced.rows[1].owner,original,"unavailable original keeps ownership")
    eq(replaced.rows[1].result.status,"unresolved","replacement cannot infer deletion")
    eq(replaced.groups[1].reason,"original adapter unavailable","unavailable owner diagnosed")
    eq(replacement_seen~=nil,true,"new owner receives candidate opportunity only")
    eq(#replacement_seen.records,0,"outside hook verifies no publication ownership transfer")
    eq(replaced.rows[1].result.previous.definition_version,7,"unavailable old version preserved")
    local missing=assert(Driver.New():DiscoverPublished("A.lua","",publication)).reconciliation
    eq(#missing.rows,1,"no registered adapter still retains old")
    -- Incomplete/foreign result must invalidate all rows from the owner.
    local bad_results={
        {},
        {{status="deleted",previous=record,reason="guess",evidence={"text absent"},dependencies={},conditions={},
            tombstone={previous=record,definition_version=6}}},
        {{status="deleted",previous=record,reason="guess",evidence={},dependencies={},conditions={}}},
        {{status="candidate-only",reason="fake",candidate={entry={}},evidence={"fake"},dependencies={},conditions={}}},
    }
    for _,result in ipairs(bad_results) do
        original.Reconcile=function() return result end
        local report=assert(driver:DiscoverPublished("A.lua","",publication)).reconciliation
        eq(#report.rows,1,"invalid result preserves every old record")
        eq(report.rows[1].result.status,"unresolved","invalid result cannot partially delete")
        eq(report.rows[1].result.previous,record,"invalid result retains original")
    end
    original.Reconcile=function() error({}) end
    local thrown=assert(driver:DiscoverPublished("A.lua","",publication)).reconciliation
    eq(thrown.rows[1].result.status,"unresolved","hook throw preserves old")
    eq(thrown.groups[1].reason,"adapter reconciliation failed","safe hook failure reason")
    original.Reconcile=function(old)
        return {{status="deleted",previous=record,reason="complete domain absence proof",
            evidence={"adapter domain proof"},dependencies={},conditions={"transaction required"},
            tombstone={owner=original,owner_id="a",previous=record,definition_version=7}}}
    end
    local old_only=assert(driver:DiscoverPublished("A.lua","",publication)).reconciliation
    eq(old_only.rows[1].result.status,"deleted","proven old-only deletion needs no fake candidate key")
    eq(old_only.rows[1].result.candidate,nil,"old-only deletion retains no candidate")
    eq(old_only.rows[1].result.tombstone.owner,original,"tombstone retains original owner")
    eq(definition.definition_version,7,"proposed deletion never advances publication")
    local explicit=assert(R.Run(Registry.New(),publication,nil,"file missing"))
    eq(explicit.rows[1].result.status,"unresolved","missing file is unresolved")
    eq(explicit.rows[1].result.previous,record,"missing file keeps version")
    eq(R.Run(driver.adapters,publication,nil),nil,"missing failure cannot masquerade as empty source")
    eq(driver:DiscoverPublished("B.lua","",publication),nil,"wrong file rejected")
    eq(driver:DiscoverPublished("A.lua","",publication,{session_id="other"}),nil,"wrong session rejected")
    eq(driver:DiscoverPublished("A.lua","",publication,{base_revision=4}),nil,"wrong revision rejected")
    local hostile=setmetatable({},{__index=function() error("metatable used") end})
    eq(driver:DiscoverPublished("A.lua","",publication,hostile),nil,"hostile context rejected")
    eq(driver:DiscoverPublished("A.lua","",hostile),nil,"hostile publication rejected")
    local before=calls
    local old=publication.groups;publication.groups={[2]=group}
    eq(driver:DiscoverPublished("A.lua","",publication),nil,"sparse publication rejected before source")
    publication.groups=old
    eq(calls,before,"invalid scope invokes no hooks")
    eq(mutations,0,"no Locate/Inject/Commit mutations")
    eq(publication.revision,5,"reconciliation never advances revision")
    print("ReconciliationSpec: "..passed.." passed, 0 failed")
    return {passed=passed,failed=0}
end
return M
