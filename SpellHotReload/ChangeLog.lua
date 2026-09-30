--------------------------------------------------------------------------------
--- SpellHotReload.ChangeLog
---
--- Bounded, in-memory record of watcher / candidate / apply / restart events,
--- surfaced in the dedicated "Change Log" tab. Entries carry a monotonic id, a
--- level used for coloring, and free text. Pure module — no engine dependency.
--------------------------------------------------------------------------------

local ChangeLog = {}
ChangeLog.__index = ChangeLog

local MAX_ENTRIES = 500

---@class SpellHotReload.ChangeLog
---@field entries table[]
---@field next_id integer

---@return SpellHotReload.ChangeLog
function ChangeLog.New()
    return setmetatable({
        entries = {},
        next_id = 0,
    }, ChangeLog)
end

---@param level string  "info" | "ok" | "warn" | "error"
---@param text string
function ChangeLog:Add(level, text)
    self.next_id = self.next_id + 1
    self.entries[#self.entries + 1] = {
        id = self.next_id,
        level = level,
        text = text,
    }
    if #self.entries > MAX_ENTRIES then
        table.remove(self.entries, 1)
    end
end

---@return table[]
function ChangeLog:Entries()
    return self.entries
end

---@return integer
function ChangeLog:Count()
    return #self.entries
end

function ChangeLog:Clear()
    self.entries = {}
end

return ChangeLog
