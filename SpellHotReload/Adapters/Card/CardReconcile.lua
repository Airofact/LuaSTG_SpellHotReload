-- Card-owned source evidence. No live reads, compilation, execution or writes.
-- Full source/list identity and binding safety remain Locate/commit obligations.
local M={}
local CALLBACKS={"before","init","frame","render","beforedel","del","after"}
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function label(v) return type(v)=="string" and v or "" end
function M.Run(previous,candidate,context)
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local base=previous.state
    local entries={}
    for _,entry in ipairs(candidate.entries) do
        if entry.adapter==Card then entries[entry.unit.context.class_key]=entry end
    end
    local rows,card_rows,claims,occurrences,callback_points={},{},{},{},{}
    for _,entry in ipairs(candidate.entries) do
        if entry.adapter==Card then
            for _,desc in ipairs(entry.unit.context.layout) do
                for _,point in next,desc.callback_points or {} do callback_points[point.first]=true end
                local point=desc.callback_points and desc.callback_points.init
                if point then occurrences[point.first]=(occurrences[point.first] or 0)+1 end
            end
        end
    end
    -- A domain-unmodeled write must never look like a deleted callback.
    -- Read the SAME full AST; do not parse a fragment or execute a setter.
    local Tree=require("SpellHotReload.Source.SyntaxTree")
    local hazard=false
    for _,statement in ipairs(candidate.analysis.statements) do
        local ast=statement.syntax
        local callback=Tree.Callback(ast)
        if callback and not callback_points[statement.source_range.first] then hazard=true end
        if ast.kind=="assign" then
            for _,target in ipairs(ast.targets) do
                if not Tree.IsName(target,"_tmp_sc") and not Tree.ClassKey(target) and not Tree.CardList(target) then
                    local touches=false
                    Tree.Walk(target,function(n)
                        if Tree.IsName(n,"_tmp_sc") or Tree.IsName(n,"_editor_class") then touches=true end
                    end)
                    if touches and not callback_points[statement.source_range.first] then hazard=true end
                end
            end
        end
    end
    local function row(status,record,reason,into,evidence)
        local r={status=status,previous=record,reason=reason,candidate=into,
            evidence=evidence or {},dependencies={},conditions={"fresh ownership and transaction guards required"}}
        rows[#rows+1]=r;return r
    end
    local function candidate_at(entry,slot,callback)
        return {entry=entry,slot=slot,descriptor=entry.unit.context.layout[slot],callback=callback}
    end
    -- New owners have no old runtime records. Candidate-only is an observation,
    -- never permission to seed a live card or to rewrite a list.
    if #previous.records==0 then
        for _,entry in ipairs(candidate.entries) do
            if entry.adapter==Card then
                for slot,desc in ipairs(entry.unit.context.layout) do
                    if desc.kind=="card" and desc.callbacks.init then
                        row("candidate-only",nil,"candidate card has never been published",
                            candidate_at(entry,slot),{"no previous publications for this owner"})
                    end
                end
            end
        end
        return rows
    end
    if base.owner~=Card or context.publication.revision~=base.revision then return nil end
    -- Only uniquely named, shape-preserving correspondence is proposed here.
    -- Ambiguous/reused source never wins by traversal order or equal keys.
    for _,record in ipairs(previous.records) do
        if record.kind=="card" then
            local entry=entries[record.class_key]
            local r=row("unresolved",record,"published class/card has no proven candidate correspondence")
            card_rows[record.key]=r
            if entry then
                local before,after=base.layout[record.class_key],entry.unit.context.layout
                local desc=before[record.slot]
                local old_name=label(desc.name)
                local names,old_count,new_count={},0,0
                for i,d in ipairs(before) do
                    names[i]=label(d.name);if names[i]==old_name then old_count=old_count+1 end
                end
                for _,d in ipairs(after) do if label(d.name)==old_name then new_count=new_count+1 end end
                if old_name~="" and old_count==1 and new_count==1 then
                    local slot,why=require("SpellHotReload.Adapters.Card.CardTarget").SourceSlot(before,after,
                        {slot=record.slot,name=old_name,names=names})
                    if slot then
                        r.status,r.reason="corresponding",why
                        r.candidate=candidate_at(entry,slot)
                        r.evidence={"unique named card and shape-preserving layout alignment"}
                        local point=r.candidate.descriptor.callback_points.init.first
                        local list=claims[point] or {};claims[point]=list;list[#list+1]=r
                    end
                else r.status,r.reason="ambiguous","card name is absent, duplicated or changed" end
            end
        end
    end
    for point,list in next,claims do
        if #list~=1 or occurrences[point]~=1 then
            for _,r in ipairs(list) do
                r.status,r.reason="ambiguous","candidate source has multiple occurrences or published owners"
                r.candidate,r.evidence=nil,{}
            end
        end
    end
    for _,record in ipairs(previous.records) do
        if record.kind=="callback" then
            local parent=card_rows[record.card_key]
            if parent.status~="corresponding" then
                row(parent.status,record,parent.reason)
            else
                local into=candidate_at(parent.candidate.entry,parent.candidate.slot,record.callback)
                local descriptor=into.descriptor
                local r=row("corresponding",record,"callback belongs to proven card correspondence",into,
                    {"owning card correspondence established"})
                r.dependencies={unpack(record.definition.dependencies)}
                if hazard then
                    r.status,r.reason="unresolved","candidate has an unmodeled callback/registry write"
                elseif record.definition.body~=nil and descriptor.callbacks[record.callback]==nil then
                    if record.callback=="init" then return nil end
                    r.status,r.reason="deleted","optional callback absent from complete mapped card"
                    r.tombstone={owner=previous.owner,owner_id=previous.owner_id,
                        previous=record,definition_version=record.definition_version}
                    r.conditions={"complete source remainder and effect checks must succeed",
                        "prepare saved default restoration and validate all consumers",
                        "publish tombstone only after successful atomic transaction"}
                end
            end
        elseif record.kind=="function" then
            row("unresolved",record,"helper binding and published consumer dependencies require planning")
        end
    end
    local consumed={}
    for _,r in next,card_rows do
        if r.status=="corresponding" then consumed[r.candidate.descriptor]=true end
    end
    for _,entry in ipairs(candidate.entries) do
        if entry.adapter==Card then
            local has_old=false
            for _,record in ipairs(previous.records) do
                if record.kind=="card" and record.class_key==entry.unit.context.class_key then has_old=true end
            end
            for slot,desc in ipairs(entry.unit.context.layout) do
                if desc.kind=="card" and desc.callbacks.init and not consumed[desc] then
                    row(has_old and "unresolved" or "candidate-only",nil,
                        has_old and "candidate card has no proven published correspondence" or "candidate class was never published",
                        candidate_at(entry,slot),has_old and {} or {"no previous publication in this class"})
                end
            end
        end
    end
    return rows
end
return M
