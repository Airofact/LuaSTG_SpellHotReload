-- First-load identity -> current CardVersions key, never name-based guessing.
-- Resolve(binding, capture, fresh_live) -> target | nil, locate error.
-- Check(target, fresh_binding, capture, fresh_live) -> true | nil, locate error.
-- Bindings come from trusted PracticeBinding.CaptureCurrent; this module cannot
-- prove that the caller actually re-read engine state. No phase token or lock.
-- Fresh live has {capture,snapshot,entry,session_id,classes,released?,poisoned?}.
-- Target owns copied names/restart scalars, not an alias to binding.names.
-- Full FIRST-load ownership (including other classes/placeholders) is checked.
-- No parsing, compiling, debug API, game calls, joins or publication.
-- LocateDiscovery / CheckDiscovery prove a CURRENT root source correspondence.
-- LocateFileDiscovery / CheckFileDiscovery enumerate genuine captured owners
-- without practice bindings. They prove correspondence, NOT binding safety,
-- publication permission or complete file coverage.
-- Pure tables are read-only by contract; release targets with their session.
local Card = require("SpellHotReload.Adapters.Card.Card")
local M = { Kind="SpellHotReload.CardTarget", Version=2 }
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function integer(v, minimum)
    return type(v)=="number" and v>=minimum and v<math.huge and v==math.floor(v)
end
local function dense(v)
    if not plain(v) then return nil end
    local count, maximum=0,0
    for k in next,v do
        if not integer(k,1) then return nil end
        count,maximum=count+1,math.max(maximum,k)
    end
    if count==maximum then return count end
end
local function fail(code,message,file)
    return nil,{phase="locate",code=code,message=message,file=file}
end
local function name(v) return type(v)=="string" and v or "" end
local function file_of(live)
    local entry=plain(live) and rawget(live,"entry")
    local file=plain(entry) and rawget(entry,"file")
    return type(file)=="string" and file or nil
end
local function session(capture,live)
    local file=file_of(live)
    local Files=require("SpellHotReload.Pipeline.FileVersions")
    if not Files.Validate(capture) or not plain(live) then
        return fail("unsupported","common first-load capture and fresh live required",file)
    end
    local snapshot,entry=capture.snapshot,live.entry
    local group,initial=Files.GetAdapterRecords(capture,Card)
    if not group or group.state.kind~="SpellHotReload.CardVersions" or group.state.version~=3
        or not plain(initial.evidence) then return fail("ownership","original Card contribution required",file) end
    if live.released or live.poisoned or live.capture~=capture or live.snapshot~=snapshot
        or live.session_id~=snapshot.session_id or snapshot.entry~=entry
        or entry.anchor~=snapshot.anchor or entry.file~=snapshot.file
        or entry.loaded_source~=snapshot.loaded_source or entry.reloadable~=true or entry.missing then
        return fail("stale","session, capture, anchor or common publication snapshot changed",file)
    end
    return {base=group.state,group=group,initial=initial.evidence,snapshot=snapshot,entry=entry,file=snapshot.file}
end
local function ownership(base,capture,live,file)
    local group,initial=require("SpellHotReload.Pipeline.FileVersions").GetAdapterRecords(capture,Card)
    local evidence=initial and initial.evidence
    if not group or group.state~=base or not plain(evidence) or dense(base.order)==nil or not plain(base.units) then
        return fail("ownership","actual Card contribution required",file)
    end
    if evidence.empty then
        if #base.order~=0 or next(base.units) or #evidence.ownership~=0 then
            return fail("ownership","empty Card contribution changed",file)
        end
        return {}
    end
    if not plain(live.classes) or live.classes~=evidence.classes
        or dense(evidence.ownership)==nil then
        return fail("ownership","first-load class ownership required",file)
    end
    local owners,seen={},{}
    for _,owner in ipairs(evidence.ownership) do
        if not plain(owner) or type(owner.class_key)~="string" or owners[owner.class_key]
            or not plain(owner.class) or rawget(live.classes,owner.class_key)~=owner.class
            or not rawequal(rawget(owner.class,"cards"),owner.list) or dense(owner.slots)==nil
            or dense(owner.list)~=#owner.slots then
            return fail("ownership","first-load class/list ownership changed",file)
        end
        owners[owner.class_key]=owner
        for slot,card in ipairs(owner.slots) do
            if not plain(card) or seen[card] or rawget(owner.list,slot)~=card then
                return fail("ownership","first-load slot ownership changed",file)
            end
            seen[card]=true
        end
    end
    local units={}
    for _,key in ipairs(base.order) do
        local unit=rawget(base.units,key)
        local owner=plain(unit) and owners[unit.class_key]
        if type(key)~="string" or units[key] or not owner or unit.key~=key
            or not integer(unit.slot,1)
            or key~="card:"..#unit.class_key..":"..unit.class_key..":"..unit.slot
            or rawget(owner.slots,unit.slot)~=unit.card or rawget(unit.card,"is_combat")~=true then
            return fail("ownership","published unit no longer owns its first-load combat slot",file)
        end
        units[key]=true
    end
    for key in next,base.units do
        if not units[key] then return fail("ownership","unindexed published unit",file) end
    end
    return owners
end
local function resolve(binding,capture,live)
    if not plain(binding) then
        return fail("unsupported","current binding, first-load capture and fresh live required",file_of(live))
    end
    local context,err=session(capture,live)
    if not context then return nil,err end
    local base,entry,file=context.base,context.entry,context.file
    if type(binding.class_key)~="string" or binding.class_key==""
        or not integer(binding.slot,1) or not plain(binding.card)
        or (binding.mode~="practice" and binding.mode~="debug")
        or (binding.name~=nil and type(binding.name)~="string")
        or (binding.include_previous~=nil and type(binding.include_previous)~="boolean")
        or (binding.mode=="debug" and binding.include_previous==true)
        or dense(binding.names)==nil then
        return fail("unsupported","valid live slot, mode, names and restart flags required",file)
    end
    local owners,oerr=ownership(base,capture,live,file)
    if not owners then return nil,oerr end
    local selected
    for _,key in ipairs(base.order) do
        local unit=base.units[key]
        if unit.class_key==binding.class_key and unit.slot==binding.slot and unit.card==binding.card then
            selected=unit
        end
    end
    if not selected then return fail("ownership","current card has no captured combat owner",file) end
    local owner=owners[binding.class_key]
    if #binding.names~=#owner.slots or name(rawget(binding.card,"name"))~=name(binding.name) then
        return fail("stale","current card name/list description changed",file)
    end
    local names={}
    for slot,card in ipairs(owner.slots) do
        local current=name(rawget(card,"name"))
        if rawget(binding.names,slot)~=current then
            return fail("stale","current live name description changed",file)
        end
        names[slot]=current
    end
    return {kind=M.Kind,version=M.Version,file=base.file,session_id=base.session_id,
        capture=capture,snapshot=context.snapshot,card_group=context.group,base_revision=context.snapshot.revision,entry=entry,classes=live.classes,
        key=selected.key,unit=selected,class_key=selected.class_key,class=owner.class,
        list=owner.list,card=selected.card,slot=selected.slot,name=name(binding.name),
        names=names,mode=binding.mode,include_previous=binding.include_previous==true}
end
local function check(target,binding,capture,live)
    if not plain(target) or target.kind~=M.Kind or target.version~=M.Version
        or dense(target.names)==nil then
        return fail("unsupported","resolved current target required",file_of(live))
    end
    local fresh,err=resolve(binding,capture,live)
    if not fresh then return nil,err end
    for _,field in ipairs({"file","session_id","capture","snapshot","card_group","base_revision","entry","classes",
        "key","unit","class_key","class","list","card","slot","name","mode","include_previous"}) do
        if not rawequal(rawget(target,field),rawget(fresh,field)) then
            return fail("stale","current target or restart context changed",fresh.file)
        end
    end
    if #target.names~=#fresh.names then return fail("stale","current name list changed",fresh.file) end
    for slot,value in ipairs(fresh.names) do
        if rawget(target.names,slot)~=value then return fail("stale","current name list changed",fresh.file) end
    end
    return true
end
-- Pure current-root source remapping. This locates ONE captured live owner;
-- it is not a bijection of all published units or permission to drop pending.
-- Callers must still compare versions, validate bindings and transact in a
-- trusted phase. Metadata/constructors are never replayed or published here.
local function layout_valid(layout)
    if dense(layout)==nil then return false end
    for _,desc in ipairs(layout) do
        if not plain(desc) or type(desc.kind)~="string"
            or type(desc.constructor)~="string" or not plain(desc.callbacks)
            or (desc.name~=nil and type(desc.name)~="string") then return false end
    end
    return true
end
local function shape(a,b)
    return a.kind==b.kind and a.constructor==b.constructor and a.perform==b.perform
end
local function source_slot(before,after,target)
    local slot,label=target.slot,target.name
    local function combat(i)
        local d=after[i]
        return d and d.kind=="card" and type(d.callbacks.init)=="string"
    end
    -- Moves are positional placeholders (SC Debug collapses its prefix).
    -- Named roots permit prefix/suffix cropping; unnamed roots require all
    -- old non-move siblings to remain in the one proven aligned layout.
    local function aligns(offset,crop)
        for i,desc in ipairs(before) do
            if i~=slot and desc.kind~="move" then
                local at=i+offset
                if at>=1 and at<=#after then
                    local collapsed=crop and offset<0 and at==1 and after[at].kind=="move"
                    if not collapsed and not shape(desc,after[at]) then return false end
                elseif not crop then return false end
            end
        end
        return true
    end
    if label~="" then
        local old_count,new_count,hit=0,0,nil
        for _,n in ipairs(target.names) do if n==label then old_count=old_count+1 end end
        for i,d in ipairs(after) do
            if name(d.name)==label then new_count,hit=new_count+1,i end
        end
        -- Duplicate names remain usable only with unchanged sibling shape
        -- and the exact live slot; never turn one surviving name into identity.
        if #before==#after and combat(slot) and name(after[slot].name)==label
            and aligns(0,false) then return slot,"slot" end
        local offset=hit and hit-slot
        local delta=#after-#before
        local edge_shift=offset and offset>=math.min(0,delta) and offset<=math.max(0,delta)
        if old_count==1 and new_count==1 and combat(hit) and edge_shift
            and aligns(offset,true) then return hit,"unique-name alignment" end
        if new_count==0 and #before==#after and combat(slot)
            and aligns(0,false) then return slot,"renamed in place" end
        return nil,"named root has no unique shape-preserving correspondence"
    end
    if #before==#after and combat(slot) and name(after[slot].name)==""
        and aligns(0,false) then return slot,"slot" end
    local found,reason
    for _,offset in ipairs({0,#after-#before}) do
        local at=slot+offset
        if (offset~=0 or found==nil) and combat(at) and name(after[at].name)==""
            and aligns(offset,false) then
            if found and found~=at then return nil,"unnamed layout aligns from both ends" end
            found,reason=at,offset==0 and "forward index" or "reverse index"
        end
    end
    if found then return found,reason end
    return nil,"unnamed root has no unique head/tail alignment"
end
local function discovery_classes(target,snapshot,live)
    local base,file=target.snapshot,target.file
    local common=plain(snapshot) and snapshot.common
    if not plain(common) or common.file~=file or common.session_id~=target.session_id
        or common.registry_entry~=target.entry or common.loaded_source~=base.loaded_source
        or common.base_revision~=target.base_revision or common.capture~=live.capture
        or target.snapshot~=live.capture.snapshot
        or not plain(common.source) or type(common.source.content)~="string" or live.content~=common.source.content
        or live.generation~=common.generation then
        return fail("stale","candidate discovery or fresh bytes disagree",file)
    end
    local source=common.source
    if not require("SpellHotReload.Source.FileAnalysis").Validate(source)
        or dense(snapshot.entries)==nil or not plain(snapshot.by_key)
        or not plain(snapshot.adapter_contexts) then
        return fail("unsupported","complete common-source discovery required",file)
    end
    local file_context=snapshot.adapter_contexts.card
    if not plain(file_context) or file_context.carrier~="card" or file_context.source~=source
        or dense(file_context.classes)==nil or dense(file_context.units)==nil or not plain(file_context.by_class) then
        return fail("unsupported","complete single-card discovery and private layout required",file)
    end
    local indexed,card_count={},0
    for _,entry in ipairs(snapshot.entries) do
        local unit=plain(entry) and entry.unit
        if not plain(unit) or type(unit.key)~="string" or indexed[unit.key] or snapshot.by_key[unit.key]~=entry then
            return fail("ownership","discovery entry/index disagree",file)
        end
        indexed[unit.key]=true
        if entry.adapter==Card then
            local ctx,context=unit.context,entry.context
            if not plain(ctx) or not plain(ctx.descriptor) or ctx.descriptor.unit~=unit
                or unit.carrier~="card" or not plain(context) or context.common~=common
                or not plain(context.adapter) or context.adapter.file~=file_context or context.adapter.unit~=ctx then
                return fail("ownership","single-card discovery context disagrees",file)
            end
            card_count=card_count+1
        elseif unit.carrier=="card" then return fail("ownership","card discovery has another owner",file) end
    end
    for key in next,snapshot.by_key do if not indexed[key] then return fail("ownership","unindexed discovery entry",file) end end
    if card_count~=#file_context.units then return fail("unsupported","filtered Card discovery",file) end
    for _,unit in ipairs(file_context.units) do
        if not indexed[unit.key] or snapshot.by_key[unit.key].unit~=unit then return fail("ownership","private card list has a foreign unit",file) end
    end
    local seen={}
    for _,class in ipairs(file_context.classes) do
        if not plain(class) or type(class.class_key)~="string" or seen[class.class_key]
            or file_context.by_class[class.class_key]~=class or not layout_valid(class.layout) then
            return fail("ownership","private class registration layout disagrees",file)
        end
        seen[class.class_key]=true
        for _,desc in ipairs(class.layout) do
            if desc.unit then
                local entry=snapshot.by_key[desc.unit.key]
                if not entry or entry.adapter~=Card or entry.unit~=desc.unit or entry.unit.context.descriptor~=desc then
                    return fail("ownership","slot descriptor has no matching single-card entry",file)
                end
            elseif desc.kind=="card" and type(desc.callbacks.init)=="string" then
                return fail("ownership","combat callback has no discovered card unit",file)
            end
        end
    end
    for key in next,file_context.by_class do if not seen[key] then return fail("ownership","unindexed private class layout",file) end end
    return {order=file_context.classes,by_class=file_context.by_class}

end
local function locate_discovery(target,snapshot,binding,capture,live)
    local ok,err=check(target,binding,capture,live)
    if not ok then return nil,err end
    local classes,cerr=discovery_classes(target,snapshot,live)
    if not classes then return nil,cerr end
    local base,file=target.snapshot,target.file
    local common=snapshot.common
    local chosen=classes.by_class[target.class_key]
    if not chosen then return fail("ambiguous","current class is absent from candidate",file) end
    local before=plain(target.card_group.state.layout) and target.card_group.state.layout[target.class_key]
    if not layout_valid(before) or #before~=#target.names
        or not before[target.slot] or before[target.slot].kind~="card" then
        return fail("ownership","captured source layout unavailable",file)
    end
    local after=chosen.layout
    local slot,reason=source_slot(before,after,target)
    if not slot then return fail("ambiguous",reason,file) end
    local unit=after[slot].unit;local entry=unit and snapshot.by_key[unit.key]
    if not entry then return fail("ownership","located callback has no single-card unit",file) end
    return {kind=M.Kind..".DiscoveryLocation",version=M.Version,target=target,
        discovery=snapshot,content=common.source.content,generation=common.generation,
        key=target.key,source_key=unit.key,entry=entry,descriptor=after[slot],
        candidate_slot=slot,candidate_name=name(after[slot].name),match=reason}
end
local function check_discovery(location,binding,capture,live)
    if not plain(location) or location.kind~=M.Kind..".DiscoveryLocation"
        or location.version~=M.Version then
        return fail("unsupported","resolved discovery location required",file_of(live))
    end
    local fresh,err=locate_discovery(location.target,location.discovery,binding,capture,live)
    if not fresh then return nil,err end
    for _,field in ipairs({"target","discovery","content","generation","key","source_key",
        "entry","descriptor","candidate_slot","candidate_name","match"}) do
        if not rawequal(rawget(location,field),rawget(fresh,field)) then
            return fail("stale","candidate location changed",fresh.target.file)
        end
    end
    return true
end
-- No current binding, CaptureCurrent or restart context is synthesized here.
-- Every row retains its stable publication key even when its source is absent.
local function locate_file(snapshot,capture,live)
    local context,err=session(capture,live)
    if not context then return nil,err end
    local base,file=context.base,context.file
    local owners,oerr=ownership(base,capture,live,file)
    if not owners then return nil,oerr end
    local report={kind=M.Kind..".FileDiscovery",version=M.Version,
        file=file,session_id=base.session_id,capture=capture,snapshot=context.snapshot,card_group=context.group,
        base_revision=context.snapshot.revision,entry=context.entry,classes=live.classes,
        discovery=snapshot,order={},by_key={},located={},pending={},unowned={}}
    local classes,cerr=discovery_classes(report,snapshot,live)
    if not classes then return nil,cerr end
    report.content=snapshot.common.source.content
    report.generation=snapshot.common.generation
    -- All slot identities (including placeholders) were checked above. Only
    -- source-described cards with an explicit init are publication units, as
    -- at first load; framework placeholders may still have is_combat=true.
    -- A missing generated unit remains a file-wide capture failure.
    for _,owner in ipairs(context.initial.ownership) do
        local before=plain(base.layout) and rawget(base.layout,owner.class_key)
        if not layout_valid(before) or #before~=#owner.slots then
            return fail("ownership","captured source layout unavailable",file)
        end
        for slot,card in ipairs(owner.slots) do
            local descriptor=before[slot]
            local key="card:"..#owner.class_key..":"..owner.class_key..":"..slot
            if descriptor.kind=="card" and descriptor.callbacks.init then
                if not base.units[key] or rawget(card,"is_combat")~=true then
                    return fail("ownership","unindexed captured combat owner",file)
                end
            elseif base.units[key] then
                return fail("ownership","published unit lacks captured source descriptor",file)
            end
        end
    end
    -- An init declaration's exact byte position identifies a source occurrence
    -- for CONFLICT detection only, never for guessing a live card identity.
    -- Reused _tmp_sc descriptors may occupy several slots or classes.
    local claims,occurrences={},{}
    for _,entry in ipairs(classes.order) do
        for _,desc in ipairs(entry.layout) do
            if desc.kind=="card" and type(desc.callbacks.init)=="string" then
                local point=plain(desc.callback_points) and desc.callback_points.init
                if not plain(point) or not integer(point.first,1)
                    or not integer(point.last,point.first) or point.last>#report.content then
                    return fail("ownership","candidate combat source position unavailable",file)
                end
                occurrences[point.first]=(occurrences[point.first] or 0)+1
            end
        end
    end
    for _,key in ipairs(base.order) do
        local unit=base.units[key]
        local owner=owners[unit.class_key]
        local names={}
        for slot,card in ipairs(owner.slots) do names[slot]=name(rawget(card,"name")) end
        local target={kind=M.Kind..".FileTarget",version=M.Version,key=key,unit=unit,
            class_key=unit.class_key,class=owner.class,list=owner.list,card=unit.card,
            slot=unit.slot,name=names[unit.slot],names=names}
        local row={key=key,target=target,status="source-absent",
            reason="captured class is absent from candidate; live owner retained"}
        report.order[#report.order+1]=key
        report.by_key[key]=row
        local entry=classes.by_class[unit.class_key]
        if entry then
            local after=entry.layout
            local slot,reason=source_slot(base.layout[unit.class_key],after,target)
            row.status,row.reason="unmapped",reason
            if slot then
                row.status,row.reason,row.match="located",nil,reason
                row.candidate_slot,row.candidate_name=slot,name(after[slot].name)
                row.descriptor=after[slot]
                local unit=row.descriptor.unit;row.entry=unit and snapshot.by_key[unit.key]
                if not row.entry then return fail("ownership","located source has no card unit",file) end
                row.source_key=unit.key
                local source_id=row.descriptor.callback_points.init.first
                local claim=claims[source_id] or {};claims[source_id]=claim
                claim[#claim+1]=row
            end
        end
    end
    -- Reject ALL claimants on conflict; traversal order never wins identity.
    for source_id,rows in next,claims do
        if #rows>1 or occurrences[source_id]>1 then
            for _,row in ipairs(rows) do
                row.status="ambiguous"
                row.reason=#rows>1 and "candidate source has multiple captured owners"
                    or "candidate source is reused by multiple slots"
            end
        end
    end
    for _,key in ipairs(report.order) do
        local into=report.by_key[key].status=="located" and report.located or report.pending
        into[#into+1]=key
    end
    for _,entry in ipairs(classes.order) do
        for slot,desc in ipairs(entry.layout) do
            if desc.kind=="card" and type(desc.callbacks.init)=="string" then
                local claim=claims[desc.callback_points.init.first]
                if not claim or #claim~=1 or claim[1].status~="located" then
                    report.unowned[#report.unowned+1]={status="unowned",source_key=desc.unit.key,
                        class_key=entry.class_key,candidate_slot=slot,
                        candidate_name=name(desc.name),descriptor=desc,
                        reason=claim and "candidate source has ambiguous captured ownership"
                            or "candidate combat slot has no proven captured owner"}
                end
            end
        end
    end
    return report
end
local function equal_fields(a,b,fields)
    if not plain(a) then return false end
    for _,field in ipairs(fields) do
        if not rawequal(rawget(a,field),rawget(b,field)) then return false end
    end
    return true
end
local function equal_list(a,b)
    if dense(a)~=#b then return false end
    for i,value in ipairs(b) do if not rawequal(a[i],value) then return false end end
    return true
end
local function check_file(report,capture,live)
    if not plain(report) or report.kind~=M.Kind..".FileDiscovery" or report.version~=M.Version then
        return fail("unsupported","resolved file correspondence required",file_of(live))
    end
    local fresh,err=locate_file(report.discovery,capture,live)
    if not fresh then return nil,err end
    local changed=not equal_fields(report,fresh,{"file","session_id","capture","snapshot","card_group",
        "base_revision","entry","classes","discovery","content","generation"})
        or not equal_list(report.order,fresh.order) or not equal_list(report.located,fresh.located)
        or not equal_list(report.pending,fresh.pending) or not plain(report.by_key)
        or dense(report.unowned)~=#fresh.unowned
    if changed then return fail("stale","file correspondence changed",fresh.file) end
    for key in next,report.by_key do
        if not fresh.by_key[key] then return fail("stale","file correspondence index changed",fresh.file) end
    end
    for _,key in ipairs(fresh.order) do
        local row,other=report.by_key[key],fresh.by_key[key]
        if not equal_fields(row,other,{"key","status","reason","source_key","entry",
            "descriptor","candidate_slot","candidate_name","match"})
            or not equal_fields(row.target,other.target,{"kind","version","key","unit",
                "class_key","class","list","card","slot","name"})
            or not equal_list(row.target.names,other.target.names) then
            return fail("stale","file target or source correspondence changed",fresh.file)
        end
    end
    for i,other in ipairs(fresh.unowned) do
        if not equal_fields(report.unowned[i],other,{"status","source_key","class_key",
            "candidate_slot","candidate_name","descriptor","reason"}) then
            return fail("stale","unowned candidate correspondence changed",fresh.file)
        end
    end
    return true
end
local function protected(fn,live,...)
    local ok,value,err=pcall(fn,...)
    if ok then return value,err end
    return fail("stale",type(value)=="string" and value or "current target read failed",file_of(live))
end
function M.Resolve(binding,capture,live)
    return protected(resolve,live,binding,capture,live)
end
function M.Check(target,binding,capture,live)
    return protected(check,live,target,binding,capture,live)
end
-- live.content is freshly re-read candidate bytes, not an accepted-source hash.
-- Resolve/Check retain live restart identity; candidate_slot is source-only.
function M.LocateDiscovery(target,snapshot,binding,capture,live)
    return protected(locate_discovery,live,target,snapshot,binding,capture,live)
end
function M.CheckDiscovery(location,binding,capture,live)
    return protected(check_discovery,live,location,binding,capture,live)
end
-- Requires FULL discovery and freshly read live.content. Arrays describe only
-- combat correspondence, not metadata/initializer/unknown-change completion.
-- Consumers must validate bindings, dependencies and final commit guards.
function M.LocateFileDiscovery(snapshot,capture,live)
    return protected(locate_file,live,snapshot,capture,live)
end
function M.CheckFileDiscovery(report,capture,live)
    return protected(check_file,live,report,capture,live)
end
---Pure source evidence only. Callers still need live ownership and final guards.
function M.SourceSlot(before,after,target)
    if not layout_valid(before) or not layout_valid(after) or not plain(target)
        or not integer(target.slot,1) or target.slot>#before or type(target.name)~="string"
        or dense(target.names)~=#before then return nil,"invalid source alignment input" end
    return source_slot(before,after,target)
end

-- Card-private restart proofs retain actual publication REFERENCES only. This
-- weak map owns no versions or candidate analysis and cannot authorize writes.
-- The workflow owns request state; release drops its run and hence this proof.
local restart_proofs=setmetatable({},{__mode="k"})
local restart_fields={"file","session_id","entry","anchor","capture","classes",
    "class_key","class","list","card","slot","name","raw_name","include_previous","key"}
local function restart_shape(run)
    local proof=plain(run) and restart_proofs[run]
    if not proof then return fail("ownership","Card-owned frozen restart proof required") end
    for _,field in ipairs(restart_fields) do
        if not rawequal(rawget(run,field),proof.fields[field]) then
            return fail("stale","frozen restart scalar or identity changed",proof.fields.file)
        end
    end
    return proof
end
local function freeze_restart(target,capture)
    if not plain(target) then return fail("unsupported","resolved Card target required") end
    local live={capture=capture,snapshot=capture and capture.snapshot,entry=target.entry,
        session_id=target.session_id,classes=target.classes}
    local binding={class_key=target.class_key,card=target.card,slot=target.slot,name=target.name,
        mode=target.mode,names=target.names,include_previous=target.include_previous}
    local ok,err=check(target,binding,capture,live)
    if not ok then return nil,err end
    local group,initial=require("SpellHotReload.Pipeline.FileVersions").GetAdapterRecords(capture,Card)
    local run={kind="versioned-card-restart",file=target.file,session_id=target.session_id,
        entry=target.entry,anchor=target.entry.anchor,capture=capture,classes=target.classes,
        class_key=target.class_key,class=target.class,list=target.list,card=target.card,
        slot=target.slot,name=target.name,raw_name=rawget(target.card,"name"),
        include_previous=target.include_previous,key=target.key}
    local fields={};for _,field in ipairs(restart_fields) do fields[field]=rawget(run,field) end
    restart_proofs[run]={fields=fields,base=capture.snapshot,group=group,initial=initial,
        unit=target.unit,unit_ref=target.unit.unit_ref}
    return run
end
local function restart_card_versions(before,after,delta,file)
    if dense(after.order)~=#before.order or not plain(after.units) then
        return fail("ownership","committed Card index changed",file)
    end
    local expected,actual,keys={},{},{}
    for _,ref in ipairs(delta.unit_refs) do actual[ref]=true end
    for i,key in ipairs(before.order) do
        local old,unit=before.units[key],rawget(after.units,key)
        if after.order[i]~=key or not plain(unit) or unit.key~=key or unit.card~=old.card
            or unit.unit_ref~=old.unit_ref or unit.class_key~=old.class_key or unit.slot~=old.slot
            or not plain(unit.callbacks) then return fail("ownership","committed Card identity changed",file) end
        keys[key]=true
        local changed=false
        for _,name in ipairs({"before","init","frame","render","beforedel","del","after"}) do
            local cb,previous=rawget(unit.callbacks,name),rawget(old.callbacks,name)
            if not plain(cb) or not plain(previous) or type(cb.fn)~="function" or cb.unit_ref~=old.unit_ref then
                return fail("ownership","committed callback record required",file)
            end
            local advanced=cb.fn~=previous.fn
            if cb.definition_version~=previous.definition_version+(advanced and 1 or 0)
                or not advanced and (cb.body~=previous.body or cb.signature~=previous.signature) then
                return fail("ownership","committed callback version disagrees with publication",file)
            end
            changed=changed or advanced
        end
        if unit.definition_version~=old.definition_version+(changed and 1 or 0) then
            return fail("ownership","committed Card version disagrees with callback changes",file)
        end
        if changed then expected[old.unit_ref]=true end
    end
    for key in next,after.units do if not keys[key] then return fail("ownership","foreign committed Card unit",file) end end
    for ref in next,expected do if not actual[ref] then return fail("ownership","receipt lost changed Card unit",file) end end
    for ref in next,actual do if not expected[ref] then return fail("ownership","receipt claims unchanged Card unit",file) end end
    return true
end
local function bind_restart(run,receipt,capture)
    local proof,err=restart_shape(run);if not proof then return nil,err end
    local Files=require("SpellHotReload.Pipeline.FileVersions")
    if proof.receipt or capture~=proof.fields.capture or not Files.Validate(capture)
        or not plain(receipt) or receipt.kind~="SpellHotReload.FileCommit.Receipt" or receipt.version~=1
        or receipt.file~=run.file or receipt.snapshot~=capture.snapshot
        or type(receipt.changed)~="boolean" or dense(receipt.owner_deltas)~=#proof.base.owners then
        return fail("ownership","successful common receipt for frozen capture required",run.file)
    end
    local snapshot=capture.snapshot
    if snapshot.entry~=proof.base.entry or snapshot.session_id~=proof.base.session_id
        or snapshot.anchor~=proof.base.anchor or snapshot.loaded_source~=proof.base.loaded_source
        or receipt.changed~=(snapshot~=proof.base)
        or snapshot.revision~=proof.base.revision+(receipt.changed and 1 or 0) then
        return fail("stale","receipt does not describe the next actual file publication",run.file)
    end
    local any,card_delta=false,nil
    for i,old in ipairs(proof.base.owners) do
        local group,delta=snapshot.owners[i],receipt.owner_deltas[i]
        if not plain(delta) or group.owner~=old.owner or group.owner_id~=old.owner_id
            or delta.owner~=old.owner or delta.owner_id~=old.owner_id
            or type(delta.changed)~="boolean" or dense(delta.unit_refs)==nil
            or delta.changed~=(group~=old) or delta.changed~=(#delta.unit_refs>0) then
            return fail("ownership","receipt owner delta disagrees with actual groups",run.file)
        end
        local owned,seen={},{}
        for _,unit in ipairs(old.units) do owned[unit.unit_ref]=true end
        for _,ref in ipairs(delta.unit_refs) do
            if not owned[ref] or seen[ref] then return fail("ownership","foreign or duplicate receipt unit",run.file) end
            seen[ref]=true
        end
        any=any or delta.changed
        if old.owner==Card then card_delta=delta end
    end
    if any~=receipt.changed then return fail("ownership","receipt change flag disagrees with owners",run.file) end
    local group,initial=Files.GetAdapterRecords(capture,Card)
    local unit=group and rawget(group.state.units,run.key)
    if initial~=proof.initial or not plain(unit) or unit.unit_ref~=proof.unit_ref
        or unit.card~=run.card or unit.key~=run.key or unit.class_key~=run.class_key or unit.slot~=run.slot
        or not plain(unit.callbacks) then
        return fail("ownership","committed Card target or version changed",run.file)
    end
    local valid,why=restart_card_versions(proof.group.state,group.state,card_delta,run.file)
    if not valid then return nil,why end
    for _,name in ipairs({"before","init","frame","render","beforedel","del","after"}) do
        if rawget(run.card,name)~=unit.callbacks[name].fn then
            return fail("stale","committed callback disagrees with live target",run.file)
        end
    end
    proof.receipt,proof.snapshot,proof.committed_group,proof.committed_unit=receipt,snapshot,group,unit
    return true
end
local function check_restart(run,live)
    local proof,err=restart_shape(run);if not proof then return nil,err end
    local capture=proof.fields.capture
    local Files=require("SpellHotReload.Pipeline.FileVersions")
    if not plain(live) or not proof.receipt or not Files.Validate(capture)
        or capture.snapshot~=proof.snapshot or run.snapshot~=proof.snapshot or run.receipt~=proof.receipt
        or proof.receipt.snapshot~=proof.snapshot
        or live.released or live.poisoned or live.publication_error
        or live.entry~=run.entry or live.session_id~=run.session_id
        or run.entry.anchor~=run.anchor or (run.entry.reloadable~=true and not run.entry.missing)
        or live.classes~=run.classes or rawget(run.card,"name")~=run.raw_name then
        return fail("stale","frozen restart target or session changed; restart game",run.file)
    end
    -- Missing may retire the Plugin versions lookup; the committed run retains
    -- its original capture. Do not use normal session(), which rejects Missing.
    local group,initial=Files.GetAdapterRecords(capture,Card)
    if group~=proof.committed_group or initial~=proof.initial
        or rawget(group.state.units,run.key)~=proof.committed_unit then
        return fail("stale","committed Card publication changed; restart game",run.file)
    end
    local owners,oerr=ownership(group.state,capture,live,run.file)
    if not owners then return nil,oerr end
    local owner=owners[run.class_key]
    if not owner or owner.class~=run.class or owner.list~=run.list or owner.slots[run.slot]~=run.card then
        return fail("ownership","frozen Card owner changed; restart game",run.file)
    end
    -- Preserve the established retry contract: full first-load slot identities
    -- and selected actual callbacks. Scalar values may evolve normally. Shared
    -- cell integrity is checked by publication Guards, not rescanned on Retry.
    for _,name in ipairs({"before","init","frame","render","beforedel","del","after"}) do
        local cb=proof.committed_unit.callbacks[name]
        if rawget(run.card,name)~=cb.fn then return fail("stale","committed callback changed; restart game",run.file) end
    end
    return true
end
function M.FreezeRestart(target,capture)
    return protected(freeze_restart,nil,target,capture)
end
function M.BindRestart(run,receipt,capture)
    return protected(bind_restart,nil,run,receipt,capture)
end
function M.CheckRestart(run,live)
    return protected(check_restart,live,run,live)
end

return M
