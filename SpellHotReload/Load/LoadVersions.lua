---Compatibility entry for Card-owned first-load publication metadata.
---Production calls Card.CaptureVersions -> Card.SeedVersions directly.
---Capture remains synchronous and forwards the original explicit inputs/results.
---No metadata algorithm, module cache, live reseeding or fallback lives here.
---The existing capture Kind/Version and structured error protocol are retained.
local Card = require("SpellHotReload.Adapters.Card.Card")
local M = { Kind = "SpellHotReload.LoadVersions", Version = 1 }
function M.Capture(entry, session_id, classes, defaults)
    return Card.SeedVersions(entry, session_id, classes, defaults)
end
return M
