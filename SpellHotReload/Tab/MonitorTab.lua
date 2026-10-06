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

-- Scalar projection produced by CardVersions, not a second semantic parser.
local function describe_inspection(ImGui, model, id)
    ImGui.Text(string.format("    Inspected g%s / published r%d (not commit authorization)",
        tostring(model.generation),model.revision))
    local target = model.target
    if target then
        ImGui.TextWrapped(string.format("    Selection: %s; live slot %d -> source slot %d (%s)",
            target.key,target.live_slot,target.source_slot,target.match))
    end
    ImGui.TextDisabled("    Names/constructors are not published; old live metadata is retained.")
    if not ImGui.CollapsingHeader("Published units + candidate actions##versions_" .. id) then return end
    local function row(unit)
        local flags = (unit.selected and "selected" or (unit.pending and "pending" or "keep"))
            .. (unit.affected and "; selection impact" or "")
        ImGui.TextWrapped(string.format("%s  published v%d  candidate: %s  [%s]",
            unit.key,unit.definition_version,unit.action,flags))
        local observed = {}
        for _, item in ipairs(unit.observed) do
            observed[#observed + 1] = item.name .. "=v" .. item.version
        end
        if #observed > 0 then
            ImGui.TextDisabled("    Published observations: " .. table.concat(observed,", "))
        end
    end
    for _, unit in ipairs(model.functions) do row(unit) end
    for _, unit in ipairs(model.cards) do
        row(unit)
        local callbacks = {}
        for _, item in ipairs(unit.callbacks) do
            callbacks[#callbacks + 1] = item.name .. "=v" .. item.definition_version
                .. (item.changed and " (candidate changed)" or "")
        end
        ImGui.TextWrapped("    Published callbacks: " .. table.concat(callbacks,", "))
    end
    for _, item in ipairs(model.initializers) do
        ImGui.TextWrapped("local:" .. item.name .. "  preserve-state; initialization change requires game restart")
    end
    for _, item in ipairs(model.pending_sources) do
        ImGui.TextWrapped(string.format("%s source slot %d  unowned / restart-required: %s",
            item.source_key,item.candidate_slot,item.reason))
    end
    for _, item in ipairs(model.tombstones) do
        ImGui.TextWrapped(string.format("%s published v%d  source absent / live retained: %s",
            item.key,item.definition_version,item.reason))
    end
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
        ImGui.TextDisabled("Apply: all captured definitions in that file; no restart. Dismiss: hide these bytes.")
        local has_stable = false
        for idx, file_name in ipairs(files) do
            local cand = store:GetCandidate(file_name)
            local size = cand and cand.first_content and #cand.first_content or 0
            local stable = cand ~= nil and cand.stable == true
            ImGui.Text(string.format("[%d] %s  %s bytes  %s", idx, file_name, size, stable and "stable" or "stabilizing"))
            ImGui.Text("    hash: " .. hash_short(cand and cand.first_hash))
            ImGui.TextDisabled("    " .. preview(cand and cand.first_content))

            has_stable = has_stable or stable
            local capture, why = plugin:GetVersions(file_name)
            if capture then
                ImGui.Text(string.format("    Published file revision: %d (not whole-file acceptance)",
                    capture.snapshot.revision))
            else
                ImGui.TextDisabled("    Versions unavailable: " .. tostring(why))
            end
            local partial = store:GetPartialPublication(file_name)
            if partial then
                ImGui.Text(string.format("    Last partial publication: r%d / g%d; candidate retained",
                    partial.revision,partial.generation))
            end
            local model = plugin:GetCandidateInspection(file_name,current)
            if model then describe_inspection(ImGui,model,file_name)
            else ImGui.TextDisabled("    Not inspected / inspection invalidated; Apply checks independently") end
            if stable and current and plugin:IsSandboxOk() and not Binding.IsReplay() then
                if ImGui.Button("Inspect Current##inspect_" .. file_name) then
                    local result, reason = plugin:InspectCandidate(file_name)
                    view.last_result = result and ("inspected " .. file_name .. "; not committed")
                        or ("inspection refused: " .. tostring(reason))
                end
            end

            -- File publication never restarts the current practice. These are
            -- cheap hints only; the scoped action independently checks all owners.
            if stable and capture and plugin:IsSandboxOk() and not Binding.IsReplay()
                and not plugin:HasRestartPending() then
                if ImGui.Button("Apply##apply_file_" .. file_name) then
                    view.last_result = plugin:ApplyFileFromUI(file_name)
                end
            else ImGui.TextDisabled("Apply unavailable (stable / first load / capability / replay / retry)") end
            ImGui.SameLine()
            if ImGui.Button("Dismiss##dismiss_" .. idx) then
                plugin:Dismiss(file_name)
            end
        end

        -- A cheap UI hint is not routing/commit authority. Apply performs full discovery.
        local can_apply = has_stable and plugin:IsSandboxOk() and current ~= nil
            and not Binding.IsReplay() and not plugin:HasRestartPending()
        if can_apply then
            if ImGui.Button("Apply & Restart Current") then
                view.last_result = plugin:ApplyFromUI()
            end
        else
            ImGui.TextDisabled("Apply disabled (no stable candidate / replay / sandbox / retry pending)")
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
