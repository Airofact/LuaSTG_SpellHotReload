-- Card-owned source evidence. No live reads, compilation, execution or writes.
-- Full source/list identity and binding safety remain Locate/commit obligations.
local Tree=require("SpellHotReload.Source.SyntaxTree")
local M={}
local CALLBACKS={"before","init","frame","render","beforedel","del","after"}
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function label(v) return type(v)=="string" and v or "" end
-- Class implementations/metadata are NOT Card callback writes. They stay in
-- the complete file effect policy, and deletion requires the genuine first-load
-- class identities to be rechecked before and after invalidation. No setters run.
function M.ClassWriteKey(ast)
    local target,value=Tree.SingleAssignment(ast)
    if not target or target.kind~="member" or target.separator~="." then return nil end
    local key=Tree.ClassKey(target.base)
    if not key or key=="" then return nil end
    local name=target.name
    if (name=="init" or name=="frame" or name=="render" or name=="kill") and value.kind=="function" then return key end
    if (name=="name" or name=="bgm" or name=="difficulty")
        and value.kind=="literal" and value.literal_kind=="string" then return key end
    if name=="_bg" and (value.kind=="name" and value.name~="_tmp_sc"
        and value.name~="_editor_class" and value.name~="_sc_table"
        or value.kind=="literal" and value.literal_kind=="nil") then return key end
end
local function class_signature(keys)
    if not plain(keys) then return nil end
    local pieces,previous,count={},nil,0
    for index,key in next,keys do
        if type(index)~="number" or index<1 or index~=math.floor(index) or index>#keys then return nil end
        count=count+1
    end
    if count~=#keys then return nil end
    for _,key in ipairs(keys) do
        if type(key)~="string" or key=="" or previous and previous>=key then return nil end
        pieces[#pieces+1]=#key..":"..key;previous=key
    end
    return table.concat(pieces)
end
function M.Run(previous,candidate,context)
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local base=previous.state
    local entries={}
    for _,entry in ipairs(candidate.entries) do
        if entry.adapter==Card then entries[entry.unit.context.class_key]=entry end
    end
    local rows,card_rows,claims,occurrences,callback_points,perform_points={},{},{},{},{},{}
    for _,entry in ipairs(candidate.entries) do
        if entry.adapter==Card then
            for _,desc in ipairs(entry.unit.context.layout) do
                for _,point in next,desc.callback_points or {} do callback_points[point.first]=true end
                if desc.perform_point then
                    local first=desc.perform_point.first
                    perform_points[first]=(perform_points[first] or 0)+1
                end
                local point=desc.callback_points and desc.callback_points.init
                if point then occurrences[point.first]=(occurrences[point.first] or 0)+1 end
            end
        end
    end
    -- Interpret the SAME full AST. Metadata must belong to one discovered
    -- descriptor; a class-field exception carries additional live obligations.
    local hazard,class_keys,class_seen=nil,{},{}
    local function unmodeled(statement)
        if not hazard then hazard=statement.source_range end
    end
    for _,statement in ipairs(candidate.analysis.statements) do
        local ast=statement.syntax
        local modeled=callback_points[statement.source_range.first]
            or perform_points[statement.source_range.first]==1
        local class_key=M.ClassWriteKey(ast)
        if class_key and not class_seen[class_key] then
            class_seen[class_key]=true;class_keys[#class_keys+1]=class_key
        end
        local function written(target)
            if not Tree.IsName(target,"_tmp_sc") and not Tree.ClassKey(target) and not Tree.CardList(target) then
                local touches=false
                Tree.Walk(target,function(n)
                    if Tree.IsName(n,"_tmp_sc") or Tree.IsName(n,"_editor_class") then touches=true end
                end)
                if touches and not modeled and not class_key then unmodeled(statement) end
            end
        end
        if Tree.Callback(ast) and not modeled then unmodeled(statement) end
        if ast.kind=="assign" then for _,target in ipairs(ast.targets) do written(target) end
        elseif ast.kind=="function_statement" then written(ast.target) end
    end
    table.sort(class_keys)
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
                    if slot and desc.kind==after[slot].kind and desc.constructor==after[slot].constructor
                        and desc.perform==after[slot].perform then
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
                    r.status,r.reason="unresolved",string.format(
                        "candidate has an unmodeled callback/registry write at bytes %d-%d",hazard.first,hazard.last)
                elseif record.definition.body~=nil and descriptor.callbacks[record.callback]==nil then
                    if record.callback=="init" then return nil end
                    r.status,r.reason="deleted","optional callback absent from complete mapped card"
                    r.tombstone={owner=previous.owner,owner_id=previous.owner_id,
                        previous=record,definition_version=record.definition_version,
                        class_keys=class_keys,class_signature=class_signature(class_keys)}
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
-- Resolve one exact reconciliation against the current publication. No parsing,
-- compilation or live writes. Source evidence never replaces the final Guard.
function M.Index(state,snapshot)
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local Cards=require("SpellHotReload.Adapters.Card.CardVersions")
    local Reconciliation=require("SpellHotReload.Pipeline.Reconciliation")
    local function fail(reason)
        return nil,{phase="reconcile",code="stale",message=reason,file=state.file}
    end
    local report=plain(snapshot) and snapshot.reconciliation
    local publication=plain(report) and report.publication
    if not plain(report) or report.kind~=Reconciliation.Kind or report.version~=Reconciliation.Version
        or report.snapshot~=snapshot or report.published~=false or report.problem~=nil
        or report.revision~=state.revision or report.file~=state.file
        or not Reconciliation.ValidatePublication(publication)
        or publication.revision~=state.revision or publication.file~=state.file
        or publication.session_id~=state.session_id or publication.entry~=state.entry
        or publication.loaded_source~=state.loaded_source then
        return fail("current publication reconciliation required")
    end
    local expected,err=Cards.Publication(state)
    if not expected then return nil,err end
    local originals={}
    for _,record in ipairs(expected.groups[1].records) do originals[record.key]=record end
    local group,output
    for _,g in ipairs(publication.groups) do
        if g.owner==Card then group=g end
    end
    for _,g in ipairs(report.groups) do
        if g.owner==Card then output=g end
    end
    if not group or group.owner_id~=state.owner_id or group.state~=state
        or not output or output.previous~=group or output.owner_id~=group.owner_id or output.reason then
        return fail("original Card owner reconciliation unavailable")
    end
    local records,rows={},{}
    for _,record in ipairs(group.records) do
        local old=originals[record.key]
        if not old or records[record.key] or record.definition~=old.definition
            or record.kind~=old.kind or record.definition_version~=old.definition_version then
            return fail("reconciliation publication definition changed")
        end
        records[record.key]=record
    end
    for key in next,originals do
        if not records[key] then return fail("reconciliation omitted a publication") end
    end
    for _,row in ipairs(output.rows) do
        local record=row.previous
        if record then
            if records[record.key]~=record or rows[record.key] then
                return fail("reconciliation publication row changed")
            end
            rows[record.key]=row
        end
    end
    for key in next,records do
        if not rows[key] then return fail("reconciliation omitted a publication row") end
    end
    return rows
end

-- A callback absence is executable only with the exact old-owner/version
-- tombstone and the SAME candidate occurrence used by live location.
function M.Deletion(state,snapshot,key,name,slot,descriptor,rows)
    local row=rows[key..":"..name]
    local old=state.units[key].callbacks[name]
    local tomb=plain(row) and row.tombstone
    local into=plain(row) and row.candidate
    if not row or row.status~="deleted" or name=="init" or old.body==nil
        or not plain(tomb) or tomb.owner~=state.owner or tomb.owner_id~=state.owner_id
        or tomb.previous~=row.previous or tomb.previous.definition~=old
        or tomb.definition_version~=old.definition_version
        or class_signature(tomb.class_keys)~=tomb.class_signature or type(tomb.class_signature)~="string"
        or not plain(into) or into.slot~=slot or into.descriptor~=descriptor
        or into.callback~=name or into.entry.adapter~=state.owner
        or snapshot.by_key[into.entry.unit.key]~=into.entry
        or descriptor.callbacks[name]~=nil then
        return nil,{phase="reconcile",code="ambiguous",file=state.file,unit_key=key,
            message="optional callback deletion has no current owner/version evidence"
                ..(plain(row) and type(row.reason)=="string" and ": "..row.reason or "")}
    end
    return tomb
end

-- Called by Card's final preflight, both before and after cache invalidation.
-- No new publication, default identity or old version may enter through absence.
function M.CheckPublications(selection,capture,live)
    local state,rows,checked_classes,card_tables=selection.base,nil,{},nil
    for _,pub in ipairs(selection.publications) do
        local unit=state.units[pub.unit_key]
        local old=plain(unit) and unit.callbacks[pub.key]
        local cb=plain(pub.callback) and pub.callback
        if old and cb and old.body~=nil and cb.body==nil then
            if not rows then
                local err;rows,err=M.Index(state,selection.discovery)
                if not rows then return nil,err end
            end
            local item=selection.report.by_key[pub.unit_key]
            local entry=selection.discovery.by_key[item.source_key]
            local descriptor=entry and entry.unit.context.layout[item.source_slot]
            local tomb,err=M.Deletion(state,selection.discovery,pub.unit_key,pub.key,item.source_slot,descriptor,rows)
            if not tomb then return nil,err end
            for _,key in ipairs(tomb.class_keys) do
                if not checked_classes[key] then
                    local expected=plain(capture) and plain(capture.class_bindings) and capture.class_bindings[key]
                    local valid=plain(expected) and plain(live) and live.classes==capture.classes
                        and plain(live.classes) and rawget(live.classes,key)==expected
                    -- A class alias to ANY published Card is not an unrelated
                    -- class implementation, even if its assignment text is unchanged.
                    if not card_tables then
                        card_tables={}
                        for _,unit_key in ipairs(state.order) do card_tables[state.units[unit_key].card]=true end
                    end
                    if card_tables[expected] then valid=false end
                    if not valid then
                        return nil,{phase="commit",code="stale",file=state.file,unit_key=pub.unit_key,
                            message="first-load deletion class binding changed or aliases a card: "..key}
                    end
                    checked_classes[key]=true
                end
            end
            if pub.deletion~=tomb or pub.value~=state.defaults[pub.key] or cb.fn~=pub.value
                or cb.previous~=old or pub.before~=old.fn or pub.target~=unit.card then
                return nil,{phase="commit",code="stale",file=state.file,unit_key=pub.unit_key,
                    message="callback deletion publication evidence changed"}
            end
        elseif pub.deletion~=nil then
            return nil,{phase="commit",code="stale",file=state.file,
                message="deletion evidence attached to a non-deletion publication"}
        end
    end
    return true
end
return M
