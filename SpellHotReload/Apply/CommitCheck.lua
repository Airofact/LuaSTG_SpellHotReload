-- Owner-neutral preflight. Domain checks and final mechanical reads are separate.
-- Trusted plain plans, not a sandbox. Ordinary state values are never frozen.
local Source=require("SpellHotReload.Source.FileAnalysis")
local Anchor=require("SpellHotReload.Load.Anchor")
local Versions=require("SpellHotReload.Pipeline.FileVersions")
local M={Kind="SpellHotReload.CommitCheck",Version=2}
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function integer(v) return type(v)=="number" and v>=1 and v<math.huge and v==math.floor(v) end
local function dense(v)
    if not plain(v) then return false end
    local n,max=0,0
    for k in next,v do if not integer(k) then return false end;n=n+1;max=math.max(max,k) end
    return n==max
end
local function fail(code,message,file)
    return nil,{phase="commit",code=code,message=message,file=file}
end
local function copy(v) local out={};for k,x in next,v do out[k]=x end;return out end
local function records(v)
    if not dense(v) then return nil end
    local out={}
    for _,record in ipairs(v) do if not plain(record) then return nil end;out[#out+1]=copy(record) end
    return out
end
-- Allocate all copies and snapshot metadata before flush/refresh/Consume.
function M.Seal(operation,fragments)
    if not plain(operation) or not dense(fragments) then return fail("ownership","operation and fragments required") end
    local proposed,err=Versions.Propose(operation,fragments)
    if not proposed then return nil,err end
    local op=copy(operation)
    local plan={kind="SpellHotReload.FilePlan",version=1,operation=op,fragments={},
        base_snapshot=operation.base_snapshot,proposed_snapshot=proposed,
        joins={},journal={},read_set={},capture_reads={},authority={},forbidden={},installed={},owner_deltas={}}
    local base,capture=operation.base_snapshot,operation.capture
    plan.forbidden[base.anchor]=true
    for i,old in ipairs(base.owners) do
        local initial=capture.initial_owners[i]
        local authority={cells=records(initial.authority.cells),raws=records(initial.authority.raws),units={}}
        if not authority.cells or not authority.raws or not dense(initial.authority.forbidden) then
            return fail("ownership","invalid first-load action authority",base.file)
        end
        for _,unit in ipairs(old.units) do authority.units[unit.unit_ref]=true end
        for _,fn in ipairs(initial.authority.forbidden) do
            if type(fn)~="function" then return fail("ownership","function exclusion required",base.file) end
            plan.forbidden[fn]=true
        end
        for _,fn in ipairs(old.functions) do plan.forbidden[fn]=true end
        plan.authority[old.owner]=authority
        local f=copy(fragments[i])
        f.proposed_group=proposed.owners[i]
        f.operation=op
        if type(f.owner_guard)~="function" then return fail("ownership","owner guard required",base.file) end
        for _,key in ipairs({"joins","cell_writes","raw_writes","read_set","capture_reads"}) do
            f[key]=records(f[key])
            if not f[key] then return fail("ownership","dense fragment records required",base.file) end
        end
        plan.fragments[i]=f
        local changed_units,seen_units={},{}
        for _,key in ipairs({"cell_writes","raw_writes"}) do
            for _,write in ipairs(f[key]) do
                if not seen_units[write.unit_ref] then
                    seen_units[write.unit_ref]=true;changed_units[#changed_units+1]=write.unit_ref
                end
            end
        end
        plan.owner_deltas[i]={owner=f.owner,owner_id=old.owner_id,
            changed=#changed_units>0,unit_refs=changed_units}
        for _,key in ipairs({"joins","read_set","capture_reads"}) do
            for _,record in ipairs(f[key]) do
                if record.owner~=f.owner or not authority.units[record.unit_ref] then
                    return fail("ownership","foreign action/read unit",base.file)
                end
                plan[key][#plan[key]+1]=record
            end
        end
        for _,key in ipairs({"cell_writes","raw_writes"}) do
            for _,record in ipairs(f[key]) do
                if record.owner~=f.owner or not authority.units[record.unit_ref] then
                    return fail("ownership","foreign write unit",base.file)
                end
                record.kind=key=="cell_writes" and "cell" or "raw"
                plan.journal[#plan.journal+1]=record
                local locations=plan.installed[record.value]
                if not locations then locations={};plan.installed[record.value]=locations end
                locations[#locations+1]=record
            end
        end
    end
    -- Deduplicate only records whose owner, stable unit and complete physical
    -- action/preimage are identical. Different donors/owners remain conflicts.
    local function identical(a,b,keys)
        for _,key in ipairs(keys) do if not rawequal(a[key],b[key]) then return false end end
        return true
    end
    local function unique(actions,keys)
        local out={}
        for _,action in ipairs(actions) do
            local found=false
            for _,old in ipairs(out) do if identical(action,old,keys) then found=true;break end end
            if not found then out[#out+1]=action end
        end
        return out
    end
    plan.joins=unique(plan.joins,{"owner","unit_ref","fn","index","name","anchor","donor","anchor_name"})
    plan.journal=unique(plan.journal,{"owner","unit_ref","kind","anchor","index","name","target","key","before","value"})
    if proposed~=base then
        plan.journal[#plan.journal+1]={kind="snapshot",target=capture,key="snapshot",before=base,value=proposed}
    end
    return plan
end
local function mechanical(plan,capture,live)
    local op=plain(plan) and plan.operation
    local base=plain(plan) and plan.base_snapshot
    if not plain(op) or plan.kind~="SpellHotReload.FilePlan" or plan.version~=1
        or not Versions.Validate(capture) or op.capture~=capture or op.base_snapshot~=base
        or capture.snapshot~=base or not plain(live) or live.capture~=capture or live.snapshot~=base
        or live.entry~=base.entry or op.entry~=base.entry or op.anchor~=base.anchor
        or op.file~=base.file or op.session_id~=base.session_id or op.loaded_source~=base.loaded_source
        or live.session_id~=base.session_id or live.released or live.poisoned
        or live.content~=op.source.content or live.generation~=op.generation
        or not Anchor.Live(base.entry) then return fail("stale","file operation baseline changed") end
    if not Versions.Validate({kind=capture.kind,version=capture.version,entry=capture.entry,
        initial_owners=capture.initial_owners,snapshot=plan.proposed_snapshot}) then
        return fail("ownership","sealed proposed snapshot is invalid",base.file)
    end
    local file,entry=base.file,base.entry
    local valid,err=Source.Validate(op.source)
    if not valid then return nil,err end
    if type(debug)~="table" or type(debug.getupvalue)~="function" or type(debug.setupvalue)~="function"
        or type(debug.upvaluejoin)~="function" then return fail("capability","shared-cell debug APIs unavailable",file) end
    local thread,main=coroutine.running()
    if thread and not main then return fail("phase","commit requires main thread",file) end
    for _,key in ipairs({"fragments","joins","journal","read_set","capture_reads"}) do
        if not dense(plan[key]) then return fail("ownership","dense sealed arrays required",file) end
    end
    local function cell(anchor,index,name)
        return anchor==base.anchor and integer(index) and type(name)=="string"
            and rawget(entry.slots,name)==index and debug.getupvalue(anchor,index)==name
    end
    local function permitted(record,kind)
        local authority=plan.authority[record.owner]
        if not authority or not authority.units[record.unit_ref] then return false end
        for _,allowed in ipairs(kind=="cell" and authority.cells or authority.raws) do
            if allowed.unit_ref==record.unit_ref and (kind=="cell"
                and allowed.anchor==record.anchor and allowed.index==record.index and allowed.name==record.name
                or kind=="raw" and allowed.target==record.target and allowed.key==record.key) then return true end
        end
        return false
    end
    for _,read in ipairs(plan.read_set) do
        if read.target~=nil then
            if not permitted(read,"raw") or not rawequal(rawget(read.target,read.key),read.value) then
                return fail("stale","raw read ownership or value changed",file)
            end
        elseif not permitted(read,"cell") or not cell(read.anchor,read.index,read.name)
            or not rawequal(select(2,debug.getupvalue(read.anchor,read.index)),read.value) then
            return fail("stale","function read ownership or value changed",file)
        end
    end
    local function capture_slot(record)
        return plain(record) and type(record.fn)=="function" and integer(record.index)
            and type(record.name)=="string" and record.name==record.anchor_name
            and cell(record.anchor,record.donor,record.anchor_name)
            and debug.getupvalue(record.fn,record.index)==record.name
    end
    for _,read in ipairs(plan.capture_reads) do
        if not plan.forbidden[read.fn] or not capture_slot(read) then
            return fail("stale","published capture slot changed",file)
        end
        if type(debug.upvalueid)=="function" then
            local a,b=debug.upvalueid(read.fn,read.index),debug.upvalueid(read.anchor,read.donor)
            if a==nil or b==nil or a~=b then return fail("stale","published capture was reconnected",file) end
        end
    end
    local next_functions={}
    for _,group in ipairs(plan.proposed_snapshot.owners) do
        local set={};next_functions[group.owner]=set
        for _,fn in ipairs(group.functions) do set[fn]=true end
    end
    for fn,writes in next,plan.installed do
        for _,write in ipairs(writes) do
            if not next_functions[write.owner] or not next_functions[write.owner][fn] then
                return fail("ownership","installation value absent from sealed owner projection",file)
            end
        end
    end
    local destinations={}
    for _,join in ipairs(plan.joins) do
        if not capture_slot(join) or plan.forbidden[join.fn] then
            return fail("ownership","join destination is published or invalid",file)
        end
        local installed=false
        for _,write in ipairs(plan.installed[join.fn] or {}) do
            if write.owner==join.owner and write.unit_ref==join.unit_ref then installed=true end
        end
        if not installed then return fail("ownership","join destination is not selected for installation",file) end
        local positions=destinations[join.fn]
        if not positions then positions={};destinations[join.fn]=positions end
        -- Duplicate actions are refused, rather than guessed equivalent by name.
        if positions[join.index] then return fail("conflict","duplicate join destination",file) end
        positions[join.index]=true
    end
    local cells,ids,raws={}, {}, {}
    for _,write in ipairs(plan.journal) do
        if write.kind=="cell" then
            if not permitted(write,"cell") or type(write.value)~="function" or type(write.before)~="function"
                or not cell(write.anchor,write.index,write.name) or cells[write.index]
                or not rawequal(select(2,debug.getupvalue(write.anchor,write.index)),write.before) then
                return fail("conflict","function write authority, position or preimage changed",file)
            end
            cells[write.index]=true
            if type(debug.upvalueid)=="function" then
                local id=debug.upvalueid(write.anchor,write.index)
                if id==nil or ids[id] then return fail("conflict","aliased function write positions",file) end
                ids[id]=true
            end
        elseif write.kind=="raw" then
            if not plain(write.target) or write.target==capture or not permitted(write,"raw")
                or type(write.value)~="function" or not rawequal(rawget(write.target,write.key),write.before) then
                return fail("ownership","raw write authority or preimage changed",file)
            end
            local keys=raws[write.target]
            if not keys then keys={};raws[write.target]=keys end
            if keys[write.key] then return fail("conflict","duplicate raw write position",file) end
            keys[write.key]=true
        elseif write.kind=="snapshot" then
            if write~=plan.journal[#plan.journal] or write.target~=capture or write.key~="snapshot"
                or write.before~=base or write.value~=plan.proposed_snapshot or write.value==base then
                return fail("ownership","snapshot install is kernel-reserved",file)
            end
        else return fail("ownership","unknown journal action",file) end
    end
    if plan.proposed_snapshot==base and (#plan.journal>0 or #plan.joins>0) then
        return fail("ownership","no-op carries mutations",file)
    end
    return true
end
function M.Mechanical(plan,capture,live)
    local ok,result,err=pcall(mechanical,plan,capture,live)
    if ok then return result,err end
    return fail("stale","mechanical read failed")
end
function M.Owners(plan,capture,live)
    if not plain(plan) or not dense(plan.fragments) then return fail("ownership","sealed owner fragments required") end
    for _,f in ipairs(plan.fragments) do
        local ok,result,err=pcall(f.owner_guard,f,capture,live)
        if not ok then return fail("stale","owner guard threw") end
        if result~=true then return nil,err or {phase="commit",code="stale",message="owner guard rejected"} end
    end
    return true
end
function M.Check(plan,capture,live)
    local ok,err=M.Owners(plan,capture,live)
    if not ok then return nil,err end
    return M.Mechanical(plan,capture,live)
end
return M
