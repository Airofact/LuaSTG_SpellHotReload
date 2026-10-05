-- First-load identity -> current CardVersions key, never name-based guessing.
-- Resolve(binding, capture, fresh_live) -> target | nil, locate error.
-- Check(target, fresh_binding, capture, fresh_live) -> true | nil, locate error.
-- Bindings come from trusted PracticeBinding.CaptureCurrent; this module cannot
-- prove that the caller actually re-read engine state. No phase token or lock.
-- Fresh live has {capture,snapshot,entry,session_id,classes,released?,poisoned?}.
-- Target owns copied names/restart scalars, not an alias to binding.names.
-- Full FIRST-load ownership (including other classes/placeholders) is checked.
-- No parsing, compiling, debug API, game calls, joins, writes, cache or restart.
-- LocateDiscovery / CheckDiscovery prove a CURRENT root source correspondence.
-- CardVersions.Compare still refuses non-fixed layouts; production is unchanged.
-- The complete discovery stays attached; this gate is NOT all-unit remapping.
-- Pure tables are read-only by contract; release targets with their session.
local Card = require("SpellHotReload.Card")
local M = { Kind="SpellHotReload.CardTarget", Version=1 }
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
local function resolve(binding,capture,live)
    local file=file_of(live)
    if not plain(binding) or not plain(capture)
        or capture.kind~="SpellHotReload.LoadVersions" or capture.version~=1
        or not plain(capture.snapshot) or not plain(live) then
        return fail("unsupported","current binding, first-load capture and fresh live required",file)
    end
    local base,entry=capture.snapshot,live.entry
    if base.kind~="SpellHotReload.CardVersions" or base.version~=1
        or not integer(base.revision,0) or type(base.session_id)~="string"
        or base.session_id=="" or not plain(entry) or type(base.anchor)~="function"
        or type(base.file)~="string" or base.file=="" then
        return fail("unsupported","valid publication snapshot required",file)
    end
    if live.released or live.poisoned or live.capture~=capture or live.snapshot~=base
        or live.session_id~=base.session_id or base.entry~=entry
        or entry.anchor~=base.anchor or entry.file~=base.file
        or entry.loaded_source~=base.loaded_source or entry.reloadable~=true or entry.missing then
        return fail("stale","session, capture, anchor or publication snapshot changed",file)
    end
    if type(binding.class_key)~="string" or binding.class_key==""
        or not integer(binding.slot,1) or not plain(binding.card)
        or (binding.mode~="practice" and binding.mode~="debug")
        or (binding.name~=nil and type(binding.name)~="string")
        or (binding.include_previous~=nil and type(binding.include_previous)~="boolean")
        or (binding.mode=="debug" and binding.include_previous==true)
        or dense(binding.names)==nil then
        return fail("unsupported","valid live slot, mode, names and restart flags required",file)
    end
    if not plain(live.classes) or live.classes~=capture.classes
        or dense(capture.ownership)==nil or dense(base.order)==nil or not plain(base.units) then
        return fail("ownership","first-load class ownership required",file)
    end
    local owners,seen={},{}
    for _,owner in ipairs(capture.ownership) do
        if not plain(owner) or type(owner.class_key)~="string" or owners[owner.class_key]
            or not plain(owner.class) or rawget(live.classes,owner.class_key)~=owner.class
            or rawget(owner.class,"cards")~=owner.list or dense(owner.slots)==nil
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
    local units,selected={},nil
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
        if unit.class_key==binding.class_key and unit.slot==binding.slot and unit.card==binding.card then
            selected=unit
        end
    end
    for key in next,base.units do
        if not units[key] then return fail("ownership","unindexed published unit",file) end
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
        capture=capture,snapshot=base,base_revision=base.revision,entry=entry,classes=live.classes,
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
    for _,field in ipairs({"file","session_id","capture","snapshot","base_revision","entry","classes",
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
local function locate_discovery(target,snapshot,binding,capture,live)
    local ok,err=check(target,binding,capture,live)
    if not ok then return nil,err end
    local base,file=target.snapshot,target.file
    local common=plain(snapshot) and snapshot.common
    if not plain(common) or common.file~=file or common.session_id~=target.session_id
        or common.registry_entry~=target.entry or common.loaded_source~=base.loaded_source
        or common.base_revision~=target.base_revision or common.published_units~=base
        or type(common.content)~="string" or live.content~=common.content then
        return fail("stale","candidate discovery or fresh bytes disagree",file)
    end
    local analysis=snapshot.analysis
    local source=common.content
    if source:sub(1,3)=="\239\187\191" then source=source:sub(4) end
    if not plain(analysis) or common.analysis~=analysis or analysis.source~=source
        or analysis.source_offset~=#common.content-#source
        or dense(snapshot.entries)==nil or not plain(snapshot.by_key)
        or not plain(snapshot.adapter_contexts) then
        return fail("unsupported","complete source discovery required",file)
    end
    local file_context=snapshot.adapter_contexts.card
    if not plain(file_context) or file_context.carrier~="card"
        or not integer(file_context.classes,0) then
        return fail("unsupported","registered Card discovery required",file)
    end
    local indexed,classes,chosen={},0,nil
    for _,entry in ipairs(snapshot.entries) do
        local unit=plain(entry) and entry.unit
        if not plain(unit) or type(unit.key)~="string" or indexed[unit.key]
            or snapshot.by_key[unit.key]~=entry then
            return fail("ownership","discovery entry/index disagree",file)
        end
        indexed[unit.key]=true
        if entry.adapter==Card then
            local ctx,context=unit.context,entry.context
            if not plain(ctx) or type(ctx.class_key)~="string"
                or unit.key~="card:"..ctx.class_key or unit.carrier~="card"
                or not layout_valid(ctx.layout) or not plain(context)
                or context.common~=common or not plain(context.adapter)
                or context.adapter.file~=file_context or context.adapter.unit~=ctx then
                return fail("ownership","Card discovery context disagrees",file)
            end
            classes=classes+1
            if ctx.class_key==target.class_key then chosen=entry end
        elseif unit.carrier=="card" then
            return fail("ownership","card discovery has another owner",file)
        end
    end
    for key in next,snapshot.by_key do
        if not indexed[key] then return fail("ownership","unindexed discovery entry",file) end
    end
    if classes~=file_context.classes then
        return fail("unsupported","filtered Card discovery",file)
    end
    if not chosen then return fail("ambiguous","current class is absent from candidate",file) end
    local before=plain(base.layout) and base.layout[target.class_key]
    if not layout_valid(before) or #before~=#target.names
        or not before[target.slot] or before[target.slot].kind~="card" then
        return fail("ownership","captured source layout unavailable",file)
    end
    local after=chosen.unit.context.layout
    local slot,reason=source_slot(before,after,target)
    if not slot then return fail("ambiguous",reason,file) end
    return {kind=M.Kind..".DiscoveryLocation",version=M.Version,target=target,
        discovery=snapshot,content=common.content,generation=common.candidate_generation,
        key=target.key,source_key=chosen.unit.key,entry=chosen,descriptor=after[slot],
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
return M
