-- Select once per Lua module scope. Consumers receive the implementation table.
-- This is a source-level choice; edit this name when adding another backend.
local implementation = "TreeSitter"
if implementation == "TreeSitter" then
    return require("SpellHotReload.Source.SyntaxTreeImpl.TreeSitter")
end
error("unsupported syntax implementation: " .. tostring(implementation), 0)
