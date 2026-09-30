--------------------------------------------------------------------------------
--- SpellHotReload.View
---
--- Independent `lstg.debug` Tool window. Drives the Plugin's Tick each frame and
--- hosts two tabs (following the Inspector tab pattern):
---   * Monitor    — watcher/root state, current variant, candidates, controls
---   * Change Log — bounded record of watcher/apply/restart events
--------------------------------------------------------------------------------

local imgui_exist, imgui = pcall(require, "imgui")

local TAB = require("SpellHotReload.Tab.TabEnum")
local MonitorTab = require("SpellHotReload.Tab.MonitorTab")
local ChangeLogTab = require("SpellHotReload.Tab.ChangeLogTab")

---@class SpellHotReload.View
local View = {}

function View:getWindowName() return "Spell Hot Reload" end
function View:getMenuGroupName() return "Tool" end
function View:getEnable() return self.enable end
function View:setEnable(v) self.enable = v end

function View:initialize(plugin)
    self.plugin = plugin
    self.enable = false
    self.current_tab = TAB.MONITOR
    self.switch_to_tab = nil
    self.last_result = nil
end

function View:refresh() end

function View:update()
    if self.plugin then
        self.plugin:Tick()
    end
end

function View:layout()
    if not imgui_exist then return end
    local ImGui = imgui.ImGui

    if ImGui.BeginTabBar("SpellHotReloadTabs") then
        local F = imgui.ImGuiTabItemFlags
        local flags = {
            [TAB.MONITOR] = F.None,
            [TAB.CHANGE_LOG] = F.None,
        }

        if self.switch_to_tab then
            flags[self.switch_to_tab] = F.SetSelected
            self.current_tab = self.switch_to_tab
            self.switch_to_tab = nil
        end

        if ImGui.BeginTabItem("Monitor", true, flags[TAB.MONITOR]) then
            self.current_tab = TAB.MONITOR
            MonitorTab.layout(self)
            ImGui.EndTabItem()
        end
        if ImGui.BeginTabItem("Change Log", true, flags[TAB.CHANGE_LOG]) then
            self.current_tab = TAB.CHANGE_LOG
            ChangeLogTab.layout(self)
            ImGui.EndTabItem()
        end
        ImGui.EndTabBar()
    end
end

return View
