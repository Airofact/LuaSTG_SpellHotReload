-- First-load identity -> current CardVersions key, never name-based guessing.
-- Resolve(binding, capture, fresh_live) -> target | nil, locate error.
-- Check(target, fresh_binding, capture, fresh_live) -> true | nil, locate error.
-- Bindings come from trusted PracticeBinding.CaptureCurrent; this module cannot
-- prove that the caller actually re-read engine state. No phase token or lock.
-- Fresh live has {capture,snapshot,entry,session_id,classes,released?,poisoned?}.
-- Target owns copied names/restart scalars, not an alias to binding.names.
-- Full FIRST-load ownership (including other classes/placeholders) is checked.
-- No parsing, compiling, debug API, game calls, joins, writes, cache or restart.
-- Candidate rename/reorder/SC Debug-to-full-source remapping is NOT enabled:
-- CardVersions.Compare's fixed-layout refusal still applies independently.
-- Pure tables are read-only by contract; release targets with their session.
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
return M
