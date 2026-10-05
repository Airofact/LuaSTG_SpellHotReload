--------------------------------------------------------------------------------
--- SpellHotReload.Tab.MonitorTab
---
--- Primary tab: watcher/root/sandbox status, the current card context (normal
--- Spell Practice or SC Debug), candidate snapshots, and the Apply / Retry /
--- Dismiss / Rescan / Start-Stop controls.
--------------------------------------------------------------------------------

local imgui_exist, imgui = pcall(require, "imgui")
local Binding = require("SpellHotReload.PracticeBinding")

local function color(r, g, b, a)
    if imgui_exist then
        return imgui.ImVec4(r, g, b, a)
    end
    return nil
end

local function hash_short(hash)
    if hash == nil then return "" end
    if #hash <= 16 then return hash end
    return hash:sub(1, 16) .. "…"
end

---Compute a candidate's preview text (bounded).
---@param content string?
---@return string
local function preview(content)
    if content == nil then return "" end
    local max_len = 200
    local lines = {}
    for line in content:gmatch("([^\n]*)\n?") do
        lines[#lines + 1] = line
        if #lines >= 3 then break end
    end
    local joined = table.concat(lines, "\n")
    if #joined > max_len then joined = joined:sub(1, max_len) .. "…" end
    return joined
end

local MonitorTab = {}

---Bounded class-key cache. Candidate content is immutable once stable, so
---re-scanning a multi-hundred-KB generated file on every frame would cause
---massive per-frame garbage. Compute once per (file, content-hash) and reuse.
local scan_cache = {}
local scan_cache_keys = {}

local function cached_class_keys(cand, file_name)
    if cand == nil or cand.first_content == nil then return nil end
    local key = file_name .. "|" .. (cand.first_hash or "")
    local hit = scan_cache[key]
    if hit ~= nil then return hit end
    local Scanner = require("SpellHotReload.GeneratedBossScanner")
    local keys = Scanner.ClassKeys(cand.first_content)
    scan_cache[key] = keys
    scan_cache_keys[#scan_cache_keys + 1] = key
    if #scan_cache_keys > 32 then
        local oldest = table.remove(scan_cache_keys, 1)
        scan_cache[oldest] = nil
    end
    return keys
end

---@param view SpellHotReload.View
function MonitorTab.layout(view)
    if not imgui_exist then return end
    local ImGui = imgui.ImGui
    local plugin = view.plugin
    if plugin == nil then
        ImGui.TextDisabled("plugin not initialized")
        return
    end

    -- status
    if plugin:IsActivationPending() then
        ImGui.TextDisabled("waiting for activation…")
        return
    end

    if plugin:IsSupported() then
        ImGui.Text("Root: " .. tostring(plugin:GetRoot()))
    else
        ImGui.TextColored(color(1, 0.6, 0.2, 1), "Unsupported: " .. tostring(plugin:GetUnsupportedReason()))
    end

    if plugin:IsSandboxOk() then
        ImGui.Text("Patch capability: ok")
    else
        ImGui.TextColored(color(1, 0.4, 0.4, 1), "Patch capability: " .. tostring(plugin:GetSandboxError()))
    end

    ImGui.Text("Watching: " .. tostring(plugin:IsWatching()))
    ImGui.Separator()

    -- current variant
    local current, cerr = Binding.CaptureCurrent()
    if current == nil then
        ImGui.TextDisabled("No current card: " .. tostring(cerr))
    else
        local source = (current.mode == "debug") and "SC Debug" or "Spell Practice"
        ImGui.Text("Source: " .. source)
        ImGui.Text("Class: " .. tostring(current.class_key))
        ImGui.Text("Slot: " .. tostring(current.slot) .. "  Name: " .. tostring(current.name))
        ImGui.Text("is_sc: " .. tostring(current.card and current.card.is_sc) .. "  include_previous: " .. tostring(current.include_previous))

        local upvalues = Binding.InspectInitFunctions(current.card)
        if #upvalues > 0 then
            local names = {}
            for _, up in ipairs(upvalues) do names[#names + 1] = up.name end
            ImGui.Text("Callbacks + local functions: " .. table.concat(names, ", "))
        else
            ImGui.Text("Callbacks: inline logic")
        end
    end
    ImGui.Separator()

    -- candidates
    local store = plugin:GetStore()
    local files = store:GetCandidateFileNames()
    if #files == 0 then
        ImGui.TextDisabled("No candidate snapshots")
    else
        ImGui.Text("Candidates (" .. #files .. "):")
        local matches_current = false
        for idx, file_name in ipairs(files) do
            local cand = store:GetCandidate(file_name)
            local size = cand and cand.first_content and #cand.first_content or 0
            local stable = cand ~= nil and cand.stable == true
            ImGui.Text(string.format("[%d] %s  %s bytes  %s", idx, file_name, size, stable and "stable" or "stabilizing"))
            ImGui.Text("    hash: " .. hash_short(cand and cand.first_hash))
            ImGui.TextDisabled("    " .. preview(cand and cand.first_content))

            if current ~= nil then
                local has_class = false
                local keys = cached_class_keys(cand, file_name)
                if keys ~= nil then
                    has_class = stable and keys[current.class_key] ~= nil
                end
                matches_current = matches_current or has_class
                if has_class then
                    ImGui.TextColored(color(0.5, 1, 0.5, 1), "    matches current class")
                else
                    ImGui.TextDisabled("    (other class)")
                end
            end

            if ImGui.Button("Dismiss##dismiss_" .. idx) then
                plugin:Dismiss(file_name)
            end
        end

        local can_apply = matches_current and plugin:IsSandboxOk() and current ~= nil and not Binding.IsReplay()
        if can_apply then
            if ImGui.Button("Apply & Restart Current") then
                view.last_result = plugin:ApplyFromUI()
            end
        else
            ImGui.TextDisabled("Apply disabled (no candidate for current class / replay / sandbox)")
        end
    end

    if plugin:HasRestartPending() then
        if ImGui.Button("Retry Restart") then
            view.last_result = plugin:RetryRestartFromUI()
        end
    end

    ImGui.Separator()

    if ImGui.Button("Rescan") then
        plugin:Rescan()
    end
    ImGui.SameLine()
    if plugin:IsWatching() then
        if ImGui.Button("Stop Watching") then plugin:StopWatching() end
    else
        if ImGui.Button("Start Watching") then plugin:StartWatching() end
    end

    ImGui.Separator()

    local last = view.last_result or plugin:GetLastResult()
    if last ~= nil then
        ImGui.TextWrapped("Result: " .. tostring(last))
    end
end

return MonitorTab
