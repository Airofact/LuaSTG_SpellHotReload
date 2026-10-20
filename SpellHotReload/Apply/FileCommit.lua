-- One neutral transaction for the entire file, after every owner registered.
-- No owner callbacks after final mechanical/API/phase checks and Consume.
-- Fresh candidate joins can be discarded; attempted live writes roll back in
-- reverse, including mutate-then-throw. Failed restoration poisons the session
-- for this module's VM lifetime. OOM/native external side effects are excluded.
local Phase=require("SpellHotReload.Apply.CommitPhase")
local Guard=require("SpellHotReload.Apply.CommitCheck")
local Cache=require("SpellHotReload.Source.CodeCache")
local M={Kind="SpellHotReload.FileCommit",Version=1}
local new_phase,seal,check_owners,check_mechanical,invalidate=
    Phase.New,Guard.Seal,Guard.Owners,Guard.Mechanical,Cache.Invalidate
local protected_call,raw_write=pcall,rawset
local busy,poisoned=nil,{}
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function fail(code,message,file) return nil,{phase="commit",code=code,message=message,file=file} end
function M.New(session_id)
    if type(session_id)~="string" or session_id=="" then return fail("ownership","session id required") end
    if poisoned[session_id] then return fail("poisoned","session requires restart") end
    local gate,err=new_phase(session_id)
    if not gate then return nil,err end
    local gate_check,gate_consume,gate_run,gate_release=gate.Check,gate.Consume,gate.Run,gate.Release
    local controller,released={},false
    local function owner(self)
        if self~=controller then return fail("phase","wrong commit controller") end
        if released then return fail("stale","commit controller released") end
        if poisoned[session_id] then return fail("poisoned","session requires restart") end
        if busy then return fail("phase","file transaction is already active") end
        return true
    end
    function controller:Run(callback,...)
        local ok,problem=owner(self);if not ok then return nil,problem end
        return gate_run(gate,callback,...)
    end
    function controller:Check(token)
        local ok,problem=owner(self);if not ok then return nil,problem end
        return gate_check(gate,token,session_id)
    end
    function controller:Poisoned() return poisoned[session_id]==true end
    function controller:Release()
        if self~=controller then return fail("phase","wrong commit controller") end
        if busy then return fail("phase","release during transaction refused") end
        local ok,problem=gate_release(gate);if not ok then return nil,problem end
        released=true;return true
    end
    function controller:Commit(token,operation,fragments,live,refresh)
        local ok,problem=owner(self);if not ok then return nil,problem end
        if refresh~=nil and type(refresh)~="function" then return fail("ownership","trusted refresh required") end
        local file=plain(operation) and operation.file
        local capture=plain(operation) and operation.capture
        local function phase_check()
            return gate_check(gate,token,plain(live) and live.session_id)
        end
        ok,problem=phase_check()
        if not ok then return fail("phase","invalid file commit scope",file) end
        busy=controller
        local plan,receipt,get,set,join,id
        local prepared,ready,reason=protected_call(function()
            local p,err=seal(operation,fragments)
            if not p then return nil,err end
            plan=p
            get,set,join,id=debug.getupvalue,debug.setupvalue,debug.upvaluejoin,debug.upvalueid
            -- Allocate the receipt before the final callback-free interval.
            receipt={kind=M.Kind..".Receipt",version=M.Version,file=file,
                snapshot=p.proposed_snapshot,changed=p.proposed_snapshot~=p.base_snapshot,
                owner_deltas=p.owner_deltas}
            local checked,why=check_owners(p,capture,live)
            if not checked then return nil,why end
            checked,why=check_mechanical(p,capture,live)
            if not checked then return nil,why end
            if #p.journal+#p.joins>0 then
                local flushed,ferr=invalidate()
                if not flushed then return fail("capability",type(ferr)=="string" and ferr or "cache invalidation failed",file) end
            end
            if refresh then
                local fresh,ferr=refresh()
                if not fresh then return nil,ferr end
                live=fresh
            end
            -- All domain callbacks finish BEFORE the final native checks.
            checked,why=check_owners(p,capture,live)
            if not checked then return nil,why end
            if debug.getupvalue~=get or debug.setupvalue~=set or debug.upvaluejoin~=join or debug.upvalueid~=id then
                return fail("capability","debug APIs changed during preparation",file)
            end
            checked,why=check_mechanical(p,capture,live)
            if not checked then return nil,why end
            if debug.getupvalue~=get or debug.setupvalue~=set or debug.upvaluejoin~=join or debug.upvalueid~=id then
                return fail("capability","debug APIs changed during final reads",file)
            end
            checked,why=phase_check()
            if not checked then return fail("phase","file commit scope changed",file) end
            return true
        end)
        if not prepared or ready~=true then
            busy=nil
            if prepared and plain(reason) then
                return fail(type(reason.code)=="string" and reason.code or "ownership",
                    type(reason.message)=="string" and reason.message or "file preparation failed",file)
            end
            return fail("ownership","file preparation threw",file)
        end
        ok,problem=gate_consume(gate,token,live.session_id)
        if not ok then busy=nil;return fail("phase","file commit consumption failed",file) end
        local attempted,stage=0,"join"
        local function apply(op,value)
            if op.kind=="cell" then
                if set(op.anchor,op.index,value)~=op.name then error("cell setter failed",0) end
                local name,actual=get(op.anchor,op.index)
                if name~=op.name or not rawequal(actual,value) then error("cell postimage failed",0) end
            else
                raw_write(op.target,op.key,value)
                if not rawequal(rawget(op.target,op.key),value) then error("raw postimage failed",0) end
            end
        end
        local committed=protected_call(function()
            for _,op in ipairs(plan.joins) do
                join(op.fn,op.index,op.anchor,op.donor)
                local name,value=get(op.fn,op.index)
                local donor_name,donor_value=get(op.anchor,op.donor)
                if name~=op.name or donor_name~=op.anchor_name or not rawequal(value,donor_value) then
                    error("join postimage failed",0)
                end
                if type(id)=="function" then
                    local a,b=id(op.fn,op.index),id(op.anchor,op.donor)
                    if a==nil or b==nil or a~=b then error("join identity failed",0) end
                end
            end
            for i,op in ipairs(plan.journal) do
                stage=op.kind
                attempted=i
                apply(op,op.value)
            end
        end)
        if not committed then
            local restored=true
            for i=attempted,1,-1 do
                if not protected_call(apply,plan.journal[i],plan.journal[i].before) then restored=false end
            end
            if not restored then poisoned[session_id]=true end
            busy=nil
            if not restored then return fail("rollback","rollback failed; session poisoned, restart required",file) end
            return fail(stage=="join" and "capability" or "publish","file "..stage.." failed; live writes restored",file)
        end
        busy=nil
        return receipt
    end
    return controller
end
return M
