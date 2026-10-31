-- Observe normal Class calls during a genuine selected load. Never replay a file.
-- LoadHook receives this as its trusted capture function; Class owns the evidence.
local Load=require('SpellHotReload.Load.AnchorLoad')
local M={Kind='SpellHotReload.ClassLoad',Version=1}
local unpack=unpack or table.unpack
local function pack(...) return {n=select('#',...),...} end
local BASES={'_object','bullet','enemy','laser','laser_bent'}
function M.Capture(content,options)
    local original=rawget(_G,'Class')
    local evidence={kind=M.Kind,version=M.Version,calls={},bases={},
        registry=rawget(_G,'_editor_class'),all_class=rawget(_G,'all_class'),class_api=original}
    for _,name in ipairs(BASES) do evidence.bases[name]=rawget(_G,name) end
    if type(original)~='function' then
        local entry,err,stage=Load.Capture(content,options)
        if entry then entry.class_load=evidence end
        return entry,err,stage
    end
    local active=true
    local function observed(...)
        if not active then return original(...) end
        local caller=debug.getinfo(2,'Sl')
        local args=pack(...)
        local results=pack(original(unpack(args,1,args.n)))
        if active then
            evidence.calls[#evidence.calls+1]={base=args[1],define=args[2],argc=args.n,
                class=results[1],arity=results.n,source=caller and caller.source,
                line=caller and caller.currentline}
        end
        return unpack(results,1,results.n)
    end
    rawset(_G,'Class',observed)
    local result=pack(pcall(Load.Capture,content,options))
    active=false
    evidence.intact=rawget(_G,'Class')==observed
    if evidence.intact then rawset(_G,'Class',original) end
    -- A later wrapper must not root all observed classes through this closure.
    local captured=evidence
    evidence=nil
    if not result[1] then error(result[2],0) end
    local entry=result[2]
    if type(entry)=='table' then
        captured.intact=captured.intact and captured.registry==rawget(_G,'_editor_class')
            and captured.all_class==rawget(_G,'all_class')
        for _,name in ipairs(BASES) do
            if captured.bases[name]~=rawget(_G,name) then captured.intact=false end
        end
        entry.class_load=captured
    end
    return unpack(result,2,result.n)
end
return M
