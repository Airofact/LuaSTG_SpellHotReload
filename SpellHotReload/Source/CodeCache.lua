--------------------------------------------------------------------------------
--- SpellHotReload.Source.CodeCache
---
--- Mutation boundary for LuaJIT code which may have constified an upvalue or
--- inlined its reader. debug.setupvalue/upvaluejoin do not invalidate those
--- traces. Flushing only the mutated closure misses unknown inlined callers.
--- Keep JIT enabled: invalidate the whole code cache before changing any cell
--- value or alias. A non-JIT Lua runtime has no such cache to invalidate.
--- This is a real mutation operation, not a capability/behaviour probe.
--------------------------------------------------------------------------------

local M = {}

---Invalidate compiled assumptions before a cell/alias mutation.
---No arguments to jit.flush: all callers must be covered, not one function.
---Missing/broken flush on an exposed JIT runtime refuses BEFORE the mutation.
---@return boolean
---@return string? reason
function M.Invalidate()
    local runtime = rawget(_G, "jit")
    if runtime == nil then return true end
    if type(runtime) ~= "table" then
        return false, "code cache: jit must be a table"
    end
    local flush = rawget(runtime, "flush")
    if type(flush) ~= "function" then
        return false, "code cache: jit.flush is unavailable"
    end
    local ok, err = pcall(flush)
    if not ok then
        return false, "code cache: jit.flush failed: " .. (type(err) == "string" and err or "unknown error")
    end
    return true
end

return M
