-- Card-owned source evidence. No live reads, compilation, execution or writes.
-- Full source/list identity and binding safety remain Locate/commit obligations.
local CardSyntax=require("SpellHotReload.Adapters.Card.CardSyntax")
local M={}
local CALLBACKS={"before","init","frame","render","beforedel","del","after"}
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function label(v) return type(v)=="string" and v or "" end
local ClassDefinitions=require("SpellHotReload.Adapters.Class.ClassDefinitions")
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
local function rows_for(previous,candidate,context)
    local Tree=candidate.common.source.analysis.syntax
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local base=previous.state
    local entries=context.adapter.by_class
    local rows,card_rows,claims,occurrences,callback_points,perform_points={},{},{},{},{},{}
    for _,class in ipairs(context.adapter.classes) do
            for _,desc in ipairs(class.layout) do
                for _,point in next,desc.callback_points or {} do callback_points[point.first]=true end
                if desc.perform_point then
                    local first=desc.perform_point.first
                    perform_points[first]=(perform_points[first] or 0)+1
                end
                local point=desc.callback_points and desc.callback_points.init
                if point then occurrences[point.first]=(occurrences[point.first] or 0)+1 end
            end
    end
    -- Interpret the SAME full AST. Metadata must belong to one discovered
    -- descriptor; a class-field exception carries additional live obligations.
    local hazard,class_keys,class_seen=nil,{},{}
    local function unmodeled(statement)
        if not hazard then hazard=statement.source_range end
    end
    for _,statement in ipairs(candidate.common.source.analysis.statements) do
        local ast=statement.syntax
        local modeled=callback_points[statement.source_range.first]
            or perform_points[statement.source_range.first]==1
        local class_key=ClassDefinitions.StructureWriteKey(Tree,ast)
        if class_key and not class_seen[class_key] then
            class_seen[class_key]=true;class_keys[#class_keys+1]=class_key
        end
        local function written(target)
            if not Tree.IsName(target,"_tmp_sc") and not CardSyntax.ClassKey(Tree,target) and not CardSyntax.CardList(Tree,target) then
                local touches=false
                Tree.Walk(target,function(n)
                    if Tree.IsName(n,"_tmp_sc") or Tree.IsName(n,"_editor_class") then touches=true end
                end)
                if touches and not modeled and not class_key then unmodeled(statement) end
            end
        end
        if CardSyntax.Callback(Tree,ast) and not modeled then unmodeled(statement) end
        local assignment=Tree.Match(ast,"assignment")
        local definition=Tree.Match(ast,"definition")
        if assignment then for _,target in ipairs(assignment.targets) do written(target) end
        elseif definition and definition.form=="function-statement" then written(definition.target) end
    end
    table.sort(class_keys)
    local function row(status,record,reason,into,evidence)
        local r={status=status,previous=record,reason=reason,candidate=into,
            evidence=evidence or {},dependencies={},conditions={"fresh ownership and transaction guards required"}}
        rows[#rows+1]=r;return r
    end
    local function candidate_at(class,slot,callback)
        local descriptor=class.layout[slot]
        local entry=descriptor.unit and candidate.by_key[descriptor.unit.key]
        return {entry=entry,slot=slot,descriptor=descriptor,callback=callback,class_key=class.class_key}
    end
    -- New owners have no old runtime records. Candidate-only is an observation,
    -- never permission to seed a live card or to rewrite a list.
    if #previous.records==0 then
        for _,entry in ipairs(context.adapter.classes) do
                for slot,desc in ipairs(entry.layout) do
                    if desc.kind=="card" and desc.callbacks.init then
                        row("candidate-only",nil,"candidate card has never been published",
                            candidate_at(entry,slot),{"no previous publications for this owner"})
                    end
                end
        end
        return rows
    end
    if base.owner~=Card then return nil end
    -- Only uniquely named, shape-preserving correspondence is proposed here.
    -- Ambiguous/reused source never wins by traversal order or equal keys.
    for _,record in ipairs(previous.records) do
        if record.kind=="card" then
            local entry=entries[record.class_key]
            local r=row("unresolved",record,"published class/card has no proven candidate correspondence")
            card_rows[record.key]=r
            if entry then
                local before,after=base.layout[record.class_key],entry.layout
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
                local into=candidate_at(entries[parent.candidate.class_key],parent.candidate.slot,record.callback)
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
    for _,class in ipairs(context.adapter.classes) do
        local has_old=false
        for _,record in ipairs(previous.records) do
            if record.kind=="card" and record.class_key==class.class_key then has_old=true end
        end
        for slot,desc in ipairs(class.layout) do
            if desc.kind=="card" and desc.callbacks.init and not consumed[desc] then
                row(has_old and "unresolved" or "candidate-only",nil,
                    has_old and "candidate card has no proven published correspondence" or "candidate class was never published",
                    candidate_at(class,slot),has_old and {} or {"no previous publication in this class"})
            end
        end
    end
    return rows
end
-- Public graph nodes are actual single cards. Layout and callback selection
-- stay private; source correspondence here never substitutes for live Locate.
function M.Run(previous,candidate,context)
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local Files=require("SpellHotReload.Pipeline.FileVersions")
    local source=candidate.common.source;local matched_context=context.adapter
    if not plain(matched_context) or matched_context.source~=source or not plain(matched_context.units)
        or not plain(matched_context.classes) or not plain(matched_context.by_class) then return nil end
    local group,initial=Files.Owner(candidate.common.capture,Card)
    local owned=group and previous.owner==Card and previous.state==group.state and previous.records==group.records
    if not owned and (#previous.records~=0 or #previous.units~=0) then return nil end
    local rows=rows_for(previous,candidate,context);if not rows then return nil end
    local view={kind="SpellHotReload.Card.View",version=1,source=source,discovery=candidate,
        base_group=owned and group or nil,base=owned and group.state or nil,
        initial=owned and initial.evidence or nil,match=matched_context,
        units={},by_ref={},by_key={},selectors={},choices={},rows={}}
    for _,row in ipairs(rows) do if row.previous then view.rows[row.previous.key]=row end end
    local proposals,counts={},{}
    if owned then
        for _,key in ipairs(group.state.order) do
            local old=group.state.units[key];local class=matched_context.by_class[old.class_key]
            if class then
                local before=group.state.layout[old.class_key];local names={}
                for i,desc in ipairs(before) do names[i]=label(desc.name) end
                local slot=require("SpellHotReload.Adapters.Card.CardTarget").SourceSlot(before,class.layout,
                    {slot=old.slot,name=names[old.slot],names=names})
                local desc=slot and class.layout[slot]
                local entry=desc and desc.unit and candidate.by_key[desc.unit.key]
                if entry then proposals[key]=entry;counts[entry]=(counts[entry] or 0)+1 end
            end
        end
    end
    local exports,used={},{}
    if owned then for _,key in ipairs(group.state.order) do
        local old=group.state.units[key];local ref=old.unit_ref
        local entry=proposals[key];if entry and counts[entry]~=1 then entry=nil end
        local selector={};local item={key=key,class_key=old.class_key,unit_ref=ref,keys={key},selectors={[selector]=key}}
        local records={}
        for _,record in ipairs(previous.records) do
            if record.key==key or record.card_key==key then records[#records+1]=record end
        end
        local unit={unit_ref=ref,candidate_entry=entry,previous_records=records,
            status=entry and "corresponding" or "old-only",private_ref=item}
        item.unit=unit;view.units[#view.units+1]=unit;view.by_ref[ref]=item
        view.by_key[key]=item;view.selectors[key]=selector
        if entry then used[entry]=true end
        exports[#exports+1]={unit_ref=ref,conditions={}}
    end end
    for _,entry in ipairs(candidate.entries) do
        if entry.adapter==Card and not used[entry] then
            view.units[#view.units+1]={candidate_entry=entry,previous_records={},status="candidate-only",private_ref=entry.unit.context}
        end
    end
    return {rows=rows,view=view,units=view.units,exports=exports}
end
-- Resolve the CURRENT exact original Card records against the common snapshot.
-- No Card-only publication facade, nested ledger or old revision is accepted.
function M.Index(capture,snapshot)
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local Files=require("SpellHotReload.Pipeline.FileVersions")
    local Reconciliation=require("SpellHotReload.Pipeline.Reconciliation")
    local group,initial=Files.Owner(capture,Card)
    local function fail(reason) return nil,{phase="reconcile",code="stale",message=reason,file=capture and capture.entry and capture.entry.file} end
    local report=plain(snapshot) and snapshot.reconciliation
    local publication=plain(report) and report.publication
    if not group or not plain(report) or report.kind~=Reconciliation.Kind or report.version~=Reconciliation.Version
        or report.snapshot~=snapshot or report.published~=false or report.problem~=nil
        or report.revision~=capture.snapshot.revision or snapshot.common.capture~=capture
        or not Reconciliation.ValidatePublication(publication) or publication.file~=capture.snapshot.file
        or publication.revision~=capture.snapshot.revision or publication.entry~=capture.entry
        or publication.session_id~=capture.snapshot.session_id or publication.loaded_source~=capture.snapshot.loaded_source then
        return fail("current common publication reconciliation required")
    end
    local output
    for _,candidate in ipairs(report.groups) do if candidate.owner==Card then output=candidate end end
    if not output or output.reason or output.previous.state~=group.state or output.previous.records~=group.records
        or not plain(output.view) or output.view.base_group~=group then return fail("original Card reconciliation unavailable") end
    local originals,rows={},{}
    for _,record in ipairs(group.records) do originals[record.key]=record end
    for _,row in ipairs(output.rows) do
        local record=row.previous
        if record then
            if originals[record.key]~=record or rows[record.key] then return fail("Card record correspondence replaced or duplicated") end
            rows[record.key]=row
        end
    end
    for key in next,originals do if not rows[key] then return fail("Card publication row omitted") end end
    return rows,group,initial.evidence
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
function M.CheckPublications(plan,capture,live,discovery)
    local state,rows,checked_classes,card_tables=plan.view.base,nil,{},nil
    local group,initial=require("SpellHotReload.Pipeline.FileVersions").Owner(capture,state.owner)
    if group~=plan.view.base_group or not initial then return nil,{phase="commit",code="stale",message="Card actual group changed"} end
    initial=initial.evidence
    for _,pub in ipairs(plan.publications) do
        local unit=state.units[pub.unit_key]
        local old=plain(unit) and unit.callbacks[pub.key]
        local cb=plain(pub.callback) and pub.callback
        if old and cb and old.body~=nil and cb.body==nil then
            if not rows then
                local err;rows,err=M.Index(capture,discovery)
                if not rows then return nil,err end
            end
            local item=plan.view.by_key[pub.unit_key]
            local descriptor=item.descriptor
            local tomb,err=M.Deletion(state,discovery,pub.unit_key,pub.key,item.location.candidate_slot,descriptor,rows)
            if not tomb then return nil,err end
            for _,key in ipairs(tomb.class_keys) do
                if not checked_classes[key] then
                    local expected=plain(initial.class_bindings) and initial.class_bindings[key]
                    local valid=plain(expected) and plain(live) and live.classes==initial.classes
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
