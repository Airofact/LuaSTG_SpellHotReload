--------------------------------------------------------------------------------
--- SpellHotReload.Tab.ChangeLogTab
---
--- Secondary tab: renders the plugin's bounded change log (watcher candidates,
--- apply / restart results, dismiss / rescan / start-stop events) newest first.
--------------------------------------------------------------------------------

local imgui_exist, imgui = pcall(require, "imgui")

local LEVEL_COLORS = {
    ok    = { 0.5, 1.0, 0.5 },
    warn  = { 1.0, 0.8, 0.2 },
    error = { 1.0, 0.4, 0.4 },
    info  = { 0.7, 0.7, 0.7 },
}

local function color(r, g, b, a)
    if imgui_exist then
        return imgui.ImVec4(r, g, b, a)
    end
    return nil
end

local ChangeLogTab = {}

---@param view SpellHotReload.View
function ChangeLogTab.layout(view)
    if not imgui_exist then return end
    local ImGui = imgui.ImGui
    local plugin = view.plugin
    if plugin == nil then
        ImGui.TextDisabled("plugin not initialized")
        return
    end

    local log = plugin:GetLog()
    if log == nil then
        ImGui.TextDisabled("change log unavailable")
        return
    end

    if ImGui.Button("Clear") then log:Clear() end
    ImGui.SameLine()
    ImGui.TextDisabled(string.format("%d entries", log:Count()))
    ImGui.Separator()

    local entries = log:Entries()
    if #entries == 0 then
        ImGui.TextDisabled("no changes recorded yet")
        return
    end

    if ImGui.BeginChild("ChangeLogScroll", imgui.ImVec2(0, 0), imgui.ImGuiChildFlags.Borders) then
        -- newest first
        for i = #entries, 1, -1 do
            local e = entries[i]
            local c = LEVEL_COLORS[e.level] or LEVEL_COLORS.info
            ImGui.TextColored(color(c[1], c[2], c[3], 1), string.format("#%d %s", e.id, e.text))
        end
        ImGui.EndChild()
    end
end

return ChangeLogTab
