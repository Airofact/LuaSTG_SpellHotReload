--- R3 generated-card versions and explicit current-root planning.
--- PURE service: no source chunk/body, join, write, flush, publish or restart.
--- Seed(functions, initial, defaults) requires a genuine FIRST-load function
--- snapshot (revision 0) plus ALL discovered combat-card owners and all seven
--- genuine callback identities per owner. It does not manufacture load history.
--- initial = dense { {class_key, slot, card, callbacks={name->first function}} }
--- defaults = caller-owned standard callback identities, copied at first load.
--- Card tables must be plain; raw slots only. Metadata/functions must be genuine
--- first capture, not live reads after setter/Apply. Card.SeedVersions owns
--- production capture; LoadVersions is a compatibility entry. Retain/release snapshots.
---
--- Compare(snapshot, complete_content) validates all saved raw callback identities
--- and real capture slots/sharing (when upvalueid exists); prepares analysis
--- closures by EACH callback definition point, never constructor-time locals.
--- Compare / CompareDiscovery require fixed first-load layout. CompareLocated
--- consumes ONE checked CardTarget location with fresh binding/capture/live.
--- Other changed-layout owners remain unmapped and pending, never guessed by key.
--- Absent candidate classes yield source tombstones, NOT live deletions; unclaimed
--- candidate cards stay unowned/pending_sources, NOT automatically seeded owners.
--- Only the located current root is selectable in a located report. All published
--- callbacks/captures are still checked, including absent/unmapped consumers.
--- New/deleted callbacks (except required init)
--- are modeled; deleted callbacks revert to the saved standard default identity.
--- No unknown RHS, generated wiring, alias initialization or state replay occurs.
---
--- Select(report, dense_card_keys) follows CHANGED callback candidate captures
--- and UNCHANGED callback actual saved captures to derive local-function roots.
--- FunctionVersions selects only required changed dependencies. Aliases terminate
--- the graph. Only changed callbacks of selected cards produce raw-slot proposals.
--- Unselected callback edits/local definitions remain pending in complete_content.
--- Helper-only propagation updates observations without compiling/publishing new
--- runtime consumers. Compare may compile all ANALYSIS literals; not a publish.
---
--- Next(selection) is only a proposed aggregate snapshot: R4 must atomically
--- install it AFTER all joins/cell writes/raw-slot publications succeed, or keep
--- the old snapshot. revision advances once for any nonempty definition group.
--- Local-function revision separately counts its own nonempty write groups.
--- Every callback source version and card definition version advance only on
--- that card's selected source publication; shared observations update separately.
--- loaded_source/layout/defaults never advance. Empty selection returns base.
---
--- No phase token/commit-time byte/session/target verification, journals, rollback,
--- poisoned sessions, restart contexts, Watcher acceptance, production Apply or
--- global mutable cache here. R4 must ALSO freeze/recheck class list/card ownership;
--- target table references alone do not prove live class slot identity.
--- Tables are read-only by contract, not a sandbox. upvalueid is optional, never
--- replaced with a Probe. Without it physical rejoin by outside code is unproved.
local Functions = require("SpellHotReload.Source.FunctionVersions")
local Source = require("SpellHotReload.Source.FunctionPlan")
local Card = require("SpellHotReload.Adapters.Card.Card")
local Compose = require("SpellHotReload.Source.Compose")
local Lexer = require("SpellHotReload.Source.Lexer")
local Target = require("SpellHotReload.Adapters.Card.CardTarget")
local M = { Kind = "SpellHotReload.CardVersions", Version = 1 }
local CALLBACKS = { "before", "init", "frame", "render", "beforedel", "del", "after" }
local allowed = {}
for _, name in ipairs(CALLBACKS) do allowed[name] = true end
local function plain(v) return type(v) == "table" and getmetatable(v) == nil end
local function dense(v)
    if not plain(v) then return nil end
    local count, maximum = 0, 0
    for k in next, v do
        if type(k) ~= "number" or k < 1 or k ~= math.floor(k)
            or k == math.huge then return nil end
        count, maximum = count + 1, math.max(maximum, k)
    end
    if count ~= maximum then return nil end
    return count
end
local function copy(v)
    local r = {}
    for k, value in next, v do r[k] = value end
    return r
end
local function same(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end
local function fail(code, message, state, key)
    return nil, { phase = "analyze", code = code, message = tostring(message),
        file = plain(state) and state.file or nil, unit_key = key }
end
local function key_of(class_key, slot)
    return "card:" .. #class_key .. ":" .. class_key .. ":" .. slot
end
local function signature(body)
    if body == nil then return "default" end
    local tokens = { "literal" }
    for _, t in ipairs(Lexer.Tokenize(body)) do
        tokens[#tokens + 1] = t.kind .. ":" .. #t.value .. ":" .. t.value
    end
    return table.concat(tokens, "|")
end
local function discover(content, state, snapshot)
    local scan, err
    if snapshot ~= nil then scan, err = Source.InspectDiscovery(snapshot)
    else scan, err = Source.Inspect(content) end
    if not scan then return nil, err end
    local match
    if snapshot ~= nil then
        local file_context = plain(snapshot.adapter_contexts)
            and snapshot.adapter_contexts.card or nil
        if not plain(file_context) or file_context.carrier ~= "card"
            or dense(snapshot.entries) == nil or not plain(snapshot.by_key) then
            return fail("unsupported", "complete registered Card discovery required", state)
        end
        local units = {}
        for _, entry in ipairs(snapshot.entries) do
            if not plain(entry) or not plain(entry.unit) then
                return fail("unsupported", "invalid discovery entry", state)
            end
            if entry.adapter == Card then
                local unit, ctx = entry.unit, entry.context
                if unit.carrier ~= "card" or not plain(unit.context)
                    or type(unit.context.class_key) ~= "string"
                    or unit.key ~= "card:" .. unit.context.class_key
                    or snapshot.by_key[unit.key] ~= entry or not plain(ctx)
                    or ctx.common ~= snapshot.common or not plain(ctx.adapter)
                    or ctx.adapter.file ~= file_context or ctx.adapter.unit ~= unit.context
                    or dense(unit.context.layout) == nil then
                    return fail("ownership", "Card discovery context disagrees", state)
                end
                units[#units + 1] = unit
            elseif entry.unit.carrier == "card" then
                return fail("ownership", "card unit not owned by registered Card", state)
            end
        end
        if #units ~= file_context.classes then
            return fail("unsupported", "incomplete Card discovery", state)
        end
        match = { units = units }
    else
        local merr
        match, merr = Card.Match(scan.analysis, { content = content })
        if not match then return fail(merr.code, merr.message, state, merr.unit_key) end
    end
    local layout, order, descriptors = {}, {}, {}
    for _, class in ipairs(match.units) do
        local ctx = class.context
        layout[ctx.class_key] = ctx.layout
        for slot, descriptor in ipairs(ctx.layout) do
            if descriptor.kind == "card" and descriptor.callbacks.init then
                local key = key_of(ctx.class_key, slot)
                order[#order + 1] = key
                descriptors[key] = { class_key = ctx.class_key, slot = slot,
                    descriptor = descriptor }
            end
        end
    end
    return { scan = scan, layout = layout, order = order, descriptors = descriptors }
end
local function fixed_layout(a, b)
    for class_key, layout in next, a do
        local newer = b[class_key]
        if not newer or #layout ~= #newer then return false end
        for i, desc in ipairs(layout) do
            local new = newer[i]
            if desc.kind ~= new.kind or desc.constructor ~= new.constructor
                or desc.perform ~= new.perform then return false end
        end
    end
    for class_key in next, b do if not a[class_key] then return false end end
    return true
end
local function prepare(discovery, descriptor, name, entry, defaults, state, key)
    local body = descriptor.callbacks[name]
    if not body then
        return { body = nil, signature = signature(nil), fn = defaults[name],
            dependencies = {}, visible = {}, join_plan = nil }
    end
    local point = descriptor.callback_points and descriptor.callback_points[name]
    local record
    for i, statement in ipairs(discovery.scan.analysis.statements) do
        if point and statement.source_range.first == point.first then
            record = discovery.scan.bindings.statements[i]; break
        end
    end
    if not record then return fail("unsupported", "callback definition point is not a top-level statement", state, key) end
    local visible = {}
    for local_name in next, record.visible do visible[#visible + 1] = local_name end
    table.sort(visible)
    local created, cerr = Compose.Create(body, nil, visible,
        { form = "expression", name = "CardVersions:" .. key .. ":" .. name })
    if not created then return fail("compile", cerr, state, key) end
    local plan, perr = Compose.Plan(created, entry)
    if not plan then return fail("unsupported", perr, state, key) end
    local dependencies = copy(created.used)
    table.sort(dependencies)
    return { body = body, signature = signature(body), fn = created.fn,
        dependencies = dependencies, visible = visible, join_plan = plan }
end
local function captures(record, entry, state, key)
    if record.body == nil then return {} end -- defaults are not file closures
    local live, err = Compose.Plan(record.fn, entry)
    if not live then return fail("stale", err, state, key) end
    local names = copy(live.names)
    table.sort(names)
    if not same(names, record.dependencies) then
        return fail("stale", "published callback captures changed", state, key)
    end
    for _, join in ipairs(live.joins) do
        if type(debug.upvalueid) == "function"
            and debug.upvalueid(join.fn, join.index) ~= debug.upvalueid(join.anchor, join.donor) then
            return fail("stale", "callback no longer shares the anchor cell", state, key)
        end
    end
    return live.joins
end
local function observed(unit, functions)
    local seen, result = {}, {}
    local function visit(name)
        if seen[name] then return end
        seen[name] = true
        local target = functions.units[name]
        if target then
            result[name] = target.definition_version
            for _, dep in ipairs(target.dependencies) do visit(dep) end
        end
    end
    for _, name in ipairs(CALLBACKS) do
        for _, dep in ipairs(unit.callbacks[name].dependencies) do visit(dep) end
    end
    return result
end
local function valid(state)
    if not plain(state) or state.kind ~= M.Kind or state.version ~= M.Version
        or not plain(state.functions) or state.functions.kind ~= Functions.Kind
        or state.entry ~= state.functions.entry or state.anchor ~= state.functions.anchor
        or state.loaded_source ~= state.functions.loaded_source
        or state.session_id ~= state.functions.session_id or state.file ~= state.functions.file
        or dense(state.order) == nil or not plain(state.units) or not plain(state.layout)
        or not plain(state.defaults) or type(state.revision) ~= "number"
        or state.revision < 0 or state.revision == math.huge
        or state.revision ~= math.floor(state.revision) then return false end
    local seen = {}
    for _, name in ipairs(CALLBACKS) do
        if type(state.defaults[name]) ~= "function" then return false end
    end
    for _, key in ipairs(state.order) do
        local unit = state.units[key]
        if type(key) ~= "string" or seen[key] or not plain(unit) or unit.key ~= key
            or not plain(unit.card) or not plain(unit.callbacks) or not plain(unit.observed)
            or type(unit.class_key) ~= "string" or type(unit.slot) ~= "number"
            or key ~= key_of(unit.class_key, unit.slot)
            or type(unit.definition_version) ~= "number" or unit.definition_version < 1 then return false end
        seen[key] = true
        for _, name in ipairs(CALLBACKS) do
            local cb = unit.callbacks[name]
            if not plain(cb) or type(cb.fn) ~= "function" or type(cb.signature) ~= "string"
                or dense(cb.dependencies) == nil or dense(cb.visible) == nil
                or type(cb.definition_version) ~= "number" or cb.definition_version < 1 then return false end
        end
    end
    for key in next, state.units do if not seen[key] then return false end end
    return true
end

---Seed only at trusted genuine first load. All discovered combat owners required.
function M.Seed(functions, initial, defaults)
    if not plain(functions) or functions.kind ~= Functions.Kind or functions.revision ~= 0
        or dense(initial) == nil or not plain(defaults) then
        return fail("unsupported", "first-load function snapshot, dense owners and defaults required", functions)
    end
    for _, name in ipairs(CALLBACKS) do
        if type(rawget(defaults, name)) ~= "function" then
            return fail("unsupported", "all seven standard defaults required", functions)
        end
    end
    local checked, ferr = Functions.Compare(functions, functions.loaded_source)
    if not checked then return nil, ferr end
    local discovery, derr = discover(functions.loaded_source, functions)
    if not discovery then return nil, derr end
    local owners, cards = {}, {}
    for _, owner in ipairs(initial) do
        if not plain(owner) or type(owner.class_key) ~= "string" or owner.class_key == ""
            or type(owner.slot) ~= "number" or owner.slot < 1 or owner.slot == math.huge
            or owner.slot ~= math.floor(owner.slot) or not plain(owner.card)
            or not plain(owner.callbacks) then
            return fail("unsupported", "invalid initial card owner", functions)
        end
        local key = key_of(owner.class_key, owner.slot)
        if owners[key] or cards[owner.card] or not discovery.descriptors[key] then
            return fail("ownership", "duplicate/unknown card owner", functions, key)
        end
        for name in next, owner.callbacks do
            if not allowed[name] then return fail("unsupported", "unknown initial callback", functions, key) end
        end
        owners[key], cards[owner.card] = owner, true
    end
    local state = { kind = M.Kind, version = M.Version, file = functions.file,
        functions = functions, entry = functions.entry, anchor = functions.anchor,
        loaded_source = functions.loaded_source, session_id = functions.session_id,
        revision = 0, layout = discovery.layout, order = copy(discovery.order),
        defaults = copy(defaults), units = {} }
    for _, key in ipairs(state.order) do
        local owner, desc = owners[key], discovery.descriptors[key]
        if not owner then return fail("ownership", "missing first-load card owner", functions, key) end
        local unit = { key = key, class_key = desc.class_key, slot = desc.slot,
            card = owner.card, callbacks = {}, definition_version = 1 }
        for _, name in ipairs(CALLBACKS) do
            local identity = rawget(owner.callbacks, name)
            if type(identity) ~= "function" or rawget(owner.card, name) ~= identity then
                return fail("stale", "genuine first callback identity required", functions, key)
            end
            local record, err = prepare(discovery, desc.descriptor, name, state.entry, defaults, state, key)
            if not record then return nil, err end
            if record.body == nil and identity ~= defaults[name] then
                return fail("stale", "first default callback identity mismatch", state, key)
            end
            record.fn, record.definition_version, record.join_plan = identity, 1, nil
            local actual, aerr = captures(record, state.entry, state, key)
            if not actual then return nil, aerr end
            unit.callbacks[name] = record
        end
        unit.observed = observed(unit, functions)
        state.units[key] = unit
    end
    return state
end

-- Narrow file-layout allowance. Only exact safe generated wiring statements
-- are excluded from the unknown-effect check; NEVER mask a whole class range.
-- Nonliteral calls/field writes and changed class implementations remain a
-- file-wide refusal when their effect on globals/bindings cannot be bounded.
local function safe_wiring(tokens,first,last)
    local function v(i) return tokens[i] and tokens[i].value end
    while v(last)==";" do last=last-1 end
    local function seq(at,values)
        for i,value in ipairs(values) do if v(at+i-1)~=value then return false end end
        return true
    end
    local function scalar(i,numeric)
        local start=i
        while i<=last and v(i)~="," and v(i)~=")" and v(i)~="}" do i=i+1 end
        if i==start then return nil end
        local token=tokens[start]
        if not numeric and i==start+1 and (token.kind=="string"
            or v(start)=="true" or v(start)=="false" or v(start)=="nil") then return i end
        -- Lexer represents numeric digits as symbol tokens. Prove one
        -- contiguous numeric literal, not an expression assembled by deleting
        -- whitespace (e.g. `1 - 2` or `0 x10`). No evaluation.
        local parts={}
        for j=start,i-1 do
            if j>start and tokens[j].pos~=tokens[j-1].pos+#tokens[j-1].value then return nil end
            parts[#parts+1]=v(j)
        end
        local literal=table.concat(parts)
        if literal:sub(1,1)=="-" then literal=literal:sub(2) end
        if literal=="" or not literal:match("^[%d%.]") or not tonumber(literal) then return nil end
        return i
    end
    local function constructor(at)
        if not seq(at,{"boss","."}) or (v(at+2)~="card" and v(at+2)~="move")
            or not seq(at+3,{".","New","("}) then return nil end
        local i,argument=at+6,1
        -- Literal scalars and the editor's sixth card argument {n,n,n} only.
        -- No calls, lookups, keyed/nested tables or evaluation of any argument.
        while i<=last and v(i)~=")" do
            if v(i)=="{" and v(at+2)=="card" and argument==6 then
                i=i+1
                for element=1,3 do
                    i=scalar(i,true)
                    if not i then return nil end
                    if element<3 then
                        if v(i)~="," then return nil end
                        i=i+1
                    elseif v(i)~="}" then return nil end
                end
                i=i+1
            else i=scalar(i);if not i then return nil end end
            argument=argument+1
            if v(i)=="," then
                i=i+1
                if v(i)==")" then return nil end
            elseif v(i)~=")" then return nil end
        end
        return v(i)==")" and i+1 or nil
    end
    local function list(at)
        if not seq(at,{"_editor_class","["}) or not tokens[at+2]
            or tokens[at+2].kind~="string" or not seq(at+3,{"]",".","cards"}) then return nil end
        return at+6
    end
    if seq(first,{"_tmp_sc","="}) then return constructor(first+2)==last+1 end
    if seq(first,{"_tmp_sc",".","perform","="}) then
        return first+4==last and (v(last)=="true" or v(last)=="false")
    end
    local at=list(first)
    if at and seq(at,{"=","{"}) and v(last)=="}" then
        local i=at+2
        while i<last do
            if v(i)=="_tmp_sc" then i=i+1 else i=constructor(i) end
            if not i then return false end
            if v(i)=="," then i=i+1 elseif i~=last then return false end
        end
        return i==last
    end
    if seq(first,{"table",".","insert","("}) then
        if seq(first+4,{"_sc_table",",","{"}) and tokens[first+7]
            and tokens[first+7].kind=="string" and v(first+8)=="," and tokens[first+9]
            and tokens[first+9].kind=="string" and seq(first+10,{",","_tmp_sc",",","#"}) then
            local stop=list(first+14)
            return stop and v(stop)=="," and (v(stop+1)=="false" or v(stop+1)=="true")
                and seq(stop+2,{"}",")"}) and stop+3==last or false
        end
        at=list(first+4)
        if not at or v(at)~="," or v(last)~=")" then return false end
        local stop=v(at+1)=="_tmp_sc" and at+2 or constructor(at+1)
        return stop==last
    end
    return false
end
-- Adapter-owned evidence only: recognized Card wiring/callback statements and
-- reads of generated Card bindings. Other statements are NOT compared here.
local function card_file_facts(state,source,pending_classes)
    local excluded,wiring,binding_reads,structures={},{},{},{}
    for _,definitions in next,source.definitions do
        for _,definition in ipairs(definitions) do excluded[definition.statement]=true end
    end
    for _,declaration in ipairs(source.bindings.declarations) do
        if not state.functions.units[declaration.name] then excluded[declaration.statement]=true end
    end
    for index,statement in ipairs(source.analysis.statements) do
        local tokens=source.analysis.tokens
        local first,last=statement.tok.first,statement.tok.last
        while tokens[last] and tokens[last].value==";" do last=last-1 end
        local function val(i) return tokens[i] and tokens[i].value end
        local callback
        if val(first)=="function" and val(first+1)=="_tmp_sc" and val(first+2)==":" then
            callback=allowed[val(first+3)] and val(first+4)=="("
        elseif val(first)=="_tmp_sc" and val(first+1)=="." then
            callback=allowed[val(first+2)] and val(first+3)=="="
                and val(first+4)=="function" and val(first+5)=="("
        end
        if callback then
            local stop
            for i=first,last do
                if val(i)=="end" and tokens[i].depth==1 then stop=i;break end
            end
            callback=stop==last
        end
        local wire=safe_wiring(tokens,first,last)
        if wire then
            local values={}
            for i=first,last do values[#values+1]=tokens[i].kind..":"..tokens[i].value end
            wiring[#wiring+1]=table.concat(values,"|")
        end
        structures[index]=wire or val(first)=="_BOSS_ESCAPE" or nil
        if callback or wire then excluded[index]=true end
        if not excluded[index] then
            local assign
            for i=first,last do if val(i)=="=" then assign=i;break end end
            for i=(assign and assign+1 or first),last do
                local token=tokens[i]
                if token.depth==0 and token.kind=="word" then
                    if token.value=="_tmp_sc" or token.value=="_sc_table" then binding_reads[index]=true end
                    if token.value=="_editor_class" then
                        local label=tokens[i+2]
                        local decode=val(i+1)=="[" and label and label.kind=="string"
                            and val(i+3)=="]" and (loadstring or load)("return "..label.value)
                        local name=decode and decode()
                        if not name or pending_classes[name] then binding_reads[index]=true end
                    end
                end
            end
        end
    end
    return {scan=source,excluded=excluded,wiring=table.concat(wiring,"\n"),
        binding_reads=binding_reads,structures=structures}
end
-- Newly compiled code may not assume pending class creation/registration ran.
-- Literal class lookups require the actual live registry target; dynamic class
-- lookup is conservatively blocked for changed definitions in this file scope.
local function class_binding(body,classes,state,key,pending_classes,wiring_changed)
    local tokens=Lexer.Tokenize(body)
    local reads={}
    for i,token in ipairs(tokens) do
        if wiring_changed and token.kind=="word"
            and (token.value=="_tmp_sc" or token.value=="_sc_table") then
            return fail("unsupported","candidate generated-card binding depends on unpublished wiring: "..token.value,state,key)
        end
        if token.kind=="word" and token.value=="_editor_class" then
            local open,label,close=tokens[i+1],tokens[i+2],tokens[i+3]
            if not open or open.value~="[" or not label or label.kind~="string"
                or not close or close.value~="]" then
                return fail("unsupported","dynamic class registry binding cannot be proved",state,key)
            end
            -- Evaluate a lexer-proved STRING literal only, not source/body/RHS.
            local decode=(loadstring or load)("return "..label.value)
            local name=decode and decode()
            if type(name)~="string" or not plain(rawget(classes,name)) then
                return fail("unsupported","candidate class binding is unavailable; registration remains pending",state,key)
            end
            if pending_classes[name] then
                return fail("unsupported","candidate class binding depends on unpublished layout: "..name,state,key)
            end
            reads[#reads+1]={registry=classes,key=name,value=rawget(classes,name)}
        end
    end
    return reads
end
---Full candidate report; compares each actually published callback signature.
local function compare(state, content, snapshot, location, file_location)
    if not valid(state) then return fail("unsupported", "a valid card snapshot is required", state) end
    if snapshot ~= nil then
        local common = plain(snapshot) and snapshot.common or nil
        if not plain(common) or common.file ~= state.file
            or common.session_id ~= state.session_id or common.registry_entry ~= state.entry
            or common.loaded_source ~= state.loaded_source
            or common.base_revision ~= state.revision or common.published_units ~= state then
            return fail("stale", "discovery published baseline disagrees", state)
        end
    end
    local function_diff, ferr
    local class_reads={}
    if file_location then function_diff,ferr=Functions.CompareFileDiscovery(state.functions,snapshot)
    elseif snapshot ~= nil then function_diff, ferr = Functions.CompareDiscovery(state.functions, snapshot)
    else function_diff, ferr = Functions.Compare(state.functions, content) end
    if not function_diff then return nil, ferr end
    local discovery, derr = discover(content, state, snapshot)
    if not discovery then return nil, derr end
    local pending_classes,wiring_changed,file_facts={}
    if file_location then
        for class,layout in next,state.layout do
            if not discovery.layout[class] or not fixed_layout({[class]=layout},
                {[class]=discovery.layout[class]}) then pending_classes[class]=true end
        end
        for class in next,discovery.layout do
            if not state.layout[class] then pending_classes[class]=true end
        end
        local loaded,lerr=Source.Inspect(state.loaded_source)
        if not loaded then return nil,lerr end
        for _,name in ipairs({"_tmp_sc","_sc_table","_editor_class","boss","table"}) do
            if function_diff.scan.bindings.by_name[name] or loaded.bindings.by_name[name] then
                return fail("unsupported","generated wiring name is shadowed: "..name,state)
            end
        end
        file_facts={before=card_file_facts(state,loaded,pending_classes),
            after=card_file_facts(state,function_diff.scan,pending_classes)}
        wiring_changed=file_facts.before.wiring~=file_facts.after.wiring
        for _,name in ipairs(state.functions.names) do
            local item=function_diff.by_name[name]
            if item.changed and not item.blocked then
                local safe,err=class_binding(item.item.definition.body,file_location.classes,state,"local:"..name,
                    pending_classes,wiring_changed)
                if not safe then item.blocked=err;item.action="binding-blocked"
                else for _,read in ipairs(safe) do class_reads[#class_reads+1]=read end end
            end
        end
    end
    if not location and not file_location and (not fixed_layout(state.layout, discovery.layout)
        or not same(state.order, discovery.order)) then
        return fail("ambiguous", "fixed first-load card layout changed; restart/remapping required", state)
    end
    local report = { kind = M.Kind .. ".Diff", version = M.Version, base = state,
        content = content, discovery = snapshot, functions = function_diff, by_key = {}, changed = {},
        affected = {}, read_set = {}, capture_reads = {}, class_reads=class_reads }
    local claimed = {}
    if location or file_location then
        report.location, report.unmapped, report.unowned, report.tombstones = location, {}, {}, {}
    end
    report.file_location,report.file_facts=file_location,file_facts
    local changed_functions = {}
    for _, name in ipairs(function_diff.affected) do changed_functions[name] = true end
    for _, key in ipairs(state.order) do
        local old, source = state.units[key], discovery.descriptors[key]
        if file_location then
            local proof=file_location.by_key[key]
            source=proof.status=="located" and discovery.descriptors[key_of(old.class_key,proof.candidate_slot)] or nil
            if source and source.descriptor~=proof.descriptor then
                return fail("ownership","file descriptor disagrees with full discovery",state,key)
            end
        elseif location then
            local before, after = state.layout[old.class_key], discovery.layout[old.class_key]
            -- Snapshot slot keys are lookup coordinates, not cross-version identity.
            if key == location.key then
                source = discovery.descriptors[key_of(old.class_key, location.candidate_slot)]
                if not source or source.descriptor ~= location.descriptor then
                    return fail("ownership", "located descriptor disagrees with full discovery", state, key)
                end
            elseif not after or not fixed_layout({[old.class_key]=before}, {[old.class_key]=after}) then
                source = nil
            end
        end
        local descriptor = source and source.descriptor
        local item = { key = key, previous = old, callbacks = {}, changed = false }
        if location or file_location then
            item.source_slot = source and source.slot
            item.source_key = source and ("card:" .. source.class_key)
            if source then
                local source_key = key_of(source.class_key, source.slot)
                if claimed[source_key] then
                    return fail("ownership", "candidate card has multiple published owners", state, key)
                end
                claimed[source_key] = key
            else
                item.pending = true
                item.source_status = file_location and file_location.by_key[key].status
                    or (discovery.layout[old.class_key] and "unmapped" or "source-absent")
                item.reason=file_location and file_location.by_key[key].reason
                report.unmapped[#report.unmapped + 1] = key
                if item.source_status == "source-absent" then
                    report.tombstones[#report.tombstones + 1] = { key=key, previous=old,
                        definition_version=old.definition_version, action="restart-required",
                        reason="class absent from candidate; live owner retained" }
                end
            end
        end
        for _, name in ipairs(CALLBACKS) do
            local previous = old.callbacks[name]
            if rawget(old.card, name) ~= previous.fn then
                return fail("stale", "published raw callback was externally replaced", state, key)
            end
            report.read_set[#report.read_set + 1] = { target = old.card, key = name, value = previous.fn }
            local actual, aerr = captures(previous, state.entry, state, key)
            if not actual then return nil, aerr end
            for _, read in ipairs(actual) do report.capture_reads[#report.capture_reads + 1] = read end
            local candidate, cerr
            if descriptor then
                candidate, cerr = prepare(discovery, descriptor, name, state.entry, state.defaults, state, key)
                if not candidate then
                    if not file_location then return nil,cerr end
                    item.blocked=item.blocked or cerr;candidate=copy(previous)
                end
            else
                -- Keep real published captures for impact/observations; no guessed Inject.
                candidate = copy(previous)
            end
            if previous.body and candidate.body and not same(previous.visible, candidate.visible) then
                local _,err=fail("unsupported","callback definition-point binding changed",state,key)
                if not file_location then return nil,err end
                item.blocked=item.blocked or err
            end
            candidate.changed = candidate.signature ~= previous.signature
            if file_location and candidate.changed then
                local safe,err=class_binding(candidate.body or "",file_location.classes,state,key,
                    pending_classes,wiring_changed)
                if not safe then item.blocked=item.blocked or err
                else for _,read in ipairs(safe) do class_reads[#class_reads+1]=read end end
            end
            candidate.previous = previous
            item.callbacks[name] = candidate
            item.changed = item.changed or candidate.changed
        end
        if item.blocked then
            item.pending,item.changed,item.source_status=true,false,"binding-blocked"
            item.reason=item.blocked.message
            for _,name in ipairs(CALLBACKS) do
                item.callbacks[name]=copy(old.callbacks[name])
                item.callbacks[name].previous=old.callbacks[name]
                item.callbacks[name].changed=false
            end
        end
        local impacted = item.changed
        for _, name in ipairs(CALLBACKS) do
            for _, graph in ipairs({ old.callbacks[name], item.callbacks[name] }) do
                for _, dep in ipairs(graph.dependencies) do
                    if changed_functions[dep] then impacted = true end
                end
            end
        end
        item.action = item.source_status or (item.changed and "compile-publish"
            or (impacted and "shared-impact" or "keep-definition"))
        report.by_key[key] = item
        if item.changed then report.changed[#report.changed + 1] = key end
        if impacted then report.affected[#report.affected + 1] = key end
    end
    if location or file_location then
        for _, source_key in ipairs(discovery.order) do
            if not claimed[source_key] then
                local source = discovery.descriptors[source_key]
                report.unowned[#report.unowned + 1] = { source_key="card:" .. source.class_key,
                    candidate_slot=source.slot, descriptor=source.descriptor,
                    action="restart-required", reason="no proven captured owner" }
            end
        end
    end
    if file_location then
        report.structural_pending={}
        if wiring_changed then
            report.structural_pending[#report.structural_pending+1]={source_key="file:"..state.file,
                reason="generated card/list/registration wiring is not published; live wiring retained"}
        end
        local seen={}
        for _,owner in ipairs(file_location.capture.ownership) do
            local class=owner.class_key;seen[class]=true
            if not discovery.layout[class] or not fixed_layout({[class]=state.layout[class]},
                {[class]=discovery.layout[class]}) then
                report.structural_pending[#report.structural_pending+1]={source_key="card:"..class,
                    reason="card layout/constructor metadata is not published; live list retained"}
            end
        end
        for _,entry in ipairs(file_location.discovery.entries) do
            if entry.adapter==Card and not seen[entry.unit.context.class_key] then
                report.structural_pending[#report.structural_pending+1]={source_key=entry.unit.key,
                    reason="new class/list is not registered or published"}
            end
        end
    end
    return report
end

---Explicit proven cards; SelectFile supplies all safe file roots in one call.
function M.Select(report, keys, function_keys)
    if not plain(report) or report.kind ~= M.Kind .. ".Diff" or report.version ~= M.Version
        or not valid(report.base) or not plain(report.by_key) or dense(keys) == nil then
        return fail("unsupported", "card diff and dense card keys required")
    end
    local selected, root_set = {}, {}
    for _, key in ipairs(keys) do
        if type(key) ~= "string" or not report.by_key[key] or selected[key] then
            return fail("unsupported", "unknown or duplicate current card", report.base, key)
        end
        if report.location and (key ~= report.location.key or report.by_key[key].pending) then
            return fail("ambiguous", "only the proven current root may be selected", report.base, key)
        end
        if report.file_location and report.by_key[key].pending then
            return nil,report.by_key[key].blocked or {phase="inject",code="ambiguous",file=report.base.file,
                unit_key=key,message=report.by_key[key].reason or "file card has no safe correspondence"}
        end
        selected[key] = true
        local item = report.by_key[key]
        for _, name in ipairs(CALLBACKS) do
            local cb = item.callbacks[name]
            local effective = cb.changed and cb or cb.previous
            for _, dep in ipairs(effective.dependencies) do
                if report.functions.by_name[dep] then root_set[dep] = true end
            end
        end
    end
    -- File Apply may explicitly include every captured function, including
    -- helpers not currently referenced by a card. Located/current-root callers
    -- cannot use this to expand their proven publication scope.
    if function_keys ~= nil then
        if report.location or dense(function_keys) == nil then
            return fail("unsupported", "file-scope function keys required", report.base)
        end
        local seen = {}
        for _, name in ipairs(function_keys) do
            if type(name)~="string" or not report.functions.by_name[name] or seen[name] then
                return fail("unsupported", "unknown or duplicate file function", report.base)
            end
            seen[name], root_set[name] = true, true
        end
    end
    local roots = {}
    for _, name in ipairs(report.base.functions.names) do
        if root_set[name] then roots[#roots + 1] = name end
    end
    local functions, ferr = Functions.Select(report.functions, roots)
    if not functions then return nil, ferr end
    local result = { kind = M.Kind .. ".Selection", version = M.Version,
        base = report.base, base_revision = report.base.revision, report = report,
        discovery = report.discovery,
        content = report.content, entry = report.base.entry, anchor = report.base.anchor,
        session_id = report.base.session_id, roots = copy(keys), function_roots = roots,
        functions = functions, selected = {}, pending = {}, publications = {},
        joins = copy(functions.joins), writes = copy(functions.writes),
        read_set = copy(functions.read_set), capture_reads = copy(functions.capture_reads),
        restarts = {} }
    if report.location then
        result.location = report.location
        result.pending_sources = copy(report.unowned)
        result.tombstones = copy(report.tombstones)
    end
    if report.file_location then
        result.file_location=report.file_location
        result.file_class_reads=copy(report.class_reads)
        result.pending_sources=copy(report.unowned)
        result.tombstones=copy(report.tombstones)
        result.structural_pending=copy(report.structural_pending)
    end
    for _, read in ipairs(report.read_set) do result.read_set[#result.read_set + 1] = read end
    for _, read in ipairs(report.capture_reads) do result.capture_reads[#result.capture_reads + 1] = read end
    for _, key in ipairs(report.base.order) do
        local item = report.by_key[key]
        if selected[key] then
            result.selected[#result.selected + 1] = key
            for _, name in ipairs(CALLBACKS) do
                local cb = item.callbacks[name]
                if cb.changed then
                    if cb.join_plan then
                        for _, join in ipairs(cb.join_plan.joins) do result.joins[#result.joins + 1] = join end
                    end
                    result.publications[#result.publications + 1] = {
                        unit_key = key, target = item.previous.card, key = name,
                        before = cb.previous.fn, value = cb.fn, callback = cb,
                    }
                end
            end
        elseif item.changed or item.pending then result.pending[#result.pending + 1] = key end
    end
    -- Compute actual observations under this selection, not pending graph edges.
    local next_functions, nerr = Functions.Next(functions)
    if not next_functions then return nil, nerr end
    result.affected = {}
    local written = {}
    for _, name in ipairs(functions.selected) do written[name] = true end
    for _, key in ipairs(report.base.order) do
        local item = report.by_key[key]
        local unit = { callbacks = {} }
        for _, name in ipairs(CALLBACKS) do
            local cb = item.callbacks[name]
            unit.callbacks[name] = selected[key] and cb.changed and cb or cb.previous
        end
        local impacted = selected[key] and item.changed
        for dep in next, observed(unit, next_functions) do
            if written[dep] then impacted = true end
        end
        if impacted then result.affected[#result.affected + 1] = key end
    end
    return result
end

---Propose versions only. Never install/reseed or read live as a new baseline.
function M.Next(selection)
    if not plain(selection) or selection.kind ~= M.Kind .. ".Selection"
        or selection.version ~= M.Version or not valid(selection.base)
        or dense(selection.publications) == nil or not plain(selection.functions) then
        return fail("unsupported", "a card selection is required")
    end
    local base = selection.base
    if #selection.publications == 0 and #selection.writes == 0 then return base end
    local functions, err = Functions.Next(selection.functions)
    if not functions then return nil, err end
    local result = copy(base)
    result.functions, result.revision, result.order = functions, base.revision + 1, copy(base.order)
    result.units = {}
    for _, key in ipairs(base.order) do
        local unit = copy(base.units[key])
        unit.callbacks = {}
        for _, name in ipairs(CALLBACKS) do
            unit.callbacks[name] = copy(base.units[key].callbacks[name])
            unit.callbacks[name].dependencies = copy(unit.callbacks[name].dependencies)
            unit.callbacks[name].visible = copy(unit.callbacks[name].visible)
        end
        result.units[key] = unit
    end
    local advanced = {}
    for _, publication in ipairs(selection.publications) do
        local key, name = publication.unit_key, publication.key
        local unit, cb = result.units[key], publication.callback
        unit.callbacks[name] = { body = cb.body, signature = cb.signature, fn = cb.fn,
            visible = copy(cb.visible), dependencies = copy(cb.dependencies),
            definition_version = base.units[key].callbacks[name].definition_version + 1 }
        if not advanced[key] then
            unit.definition_version = base.units[key].definition_version + 1
            advanced[key] = true
        end
    end
    for _, key in ipairs(result.order) do result.units[key].observed = observed(result.units[key], functions) end
    return result
end

---Detached scalar-only presentation of a trusted current-root selection.
---No live/source read, compilation, proposed versions, commit or authorization.
function M.Describe(selection)
    if not plain(selection) or selection.kind ~= M.Kind .. ".Selection"
        or selection.version ~= M.Version or not valid(selection.base)
        or not plain(selection.report) or selection.report.base ~= selection.base
        or not plain(selection.functions) or dense(selection.selected) == nil
        or dense(selection.pending) == nil or dense(selection.affected) == nil then
        return fail("unsupported", "a prepared card selection is required")
    end
    local function set(list)
        local result = {};for _, key in ipairs(list or {}) do result[key] = true end
        return result
    end
    local function observations(values)
        local names, result = {}, {}
        for name in next, values do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            result[#result + 1] = {name=name, version=values[name]}
        end
        return result
    end
    local base, report = selection.base, selection.report
    local selected, pending, affected = set(selection.selected), set(selection.pending), set(selection.affected)
    local result = {kind=M.Kind .. ".Description", version=M.Version, file=base.file,
        session_id=base.session_id, revision=base.revision, cards={}, functions={},
        initializers={}, pending_sources={}, tombstones={}}
    local common = selection.discovery and selection.discovery.common
    result.generation = common and common.candidate_generation
    if selection.location then
        local location, target = selection.location, selection.location.target
        result.target = {key=target.key, class_key=target.class_key, live_slot=target.slot,
            source_slot=location.candidate_slot, name=target.name, match=location.match}
    end
    for _, key in ipairs(base.order) do
        local unit, item = base.units[key], report.by_key[key]
        local row = {key=key, class_key=unit.class_key, slot=unit.slot,
            definition_version=unit.definition_version, action=item.action,
            selected=selected[key]==true, pending=pending[key]==true, affected=affected[key]==true,
            observed=observations(unit.observed), callbacks={}}
        for _, name in ipairs(CALLBACKS) do
            row.callbacks[#row.callbacks + 1] = {name=name,
                definition_version=unit.callbacks[name].definition_version,
                changed=item.callbacks[name].changed==true}
        end
        result.cards[#result.cards + 1] = row
    end
    selected, pending, affected = set(selection.functions.selected),
        set(selection.functions.pending), set(selection.functions.affected)
    for _, name in ipairs(base.functions.names) do
        local unit, item = base.functions.units[name], report.functions.by_name[name]
        result.functions[#result.functions + 1] = {key="local:" .. name,
            definition_version=unit.definition_version, action=item.action,
            selected=selected[name]==true, pending=pending[name]==true, affected=affected[name]==true,
            observed=observations(unit.observed)}
    end
    for _, item in ipairs(report.functions.initializers) do
        result.initializers[#result.initializers + 1] = {
            name=item.name, action=item.action, requires_restart=item.requires_restart==true}
    end
    for _, item in ipairs(selection.pending_sources or {}) do
        result.pending_sources[#result.pending_sources + 1] = {
            source_key=item.source_key, candidate_slot=item.candidate_slot,
            action=item.action, reason=item.reason}
    end
    for _, item in ipairs(selection.tombstones or {}) do
        result.tombstones[#result.tombstones + 1] = {key=item.key,
            definition_version=item.definition_version, action=item.action, reason=item.reason}
    end
    return result
end

---Adapter-owned statement coverage and pending definitions against actual
---publications. No unknown-statement comparison, Include policy, complete flag
---or candidate removal authority. FileApply owns full-file remainder accounting.
function M.Coverage(report)
    if not plain(report) or report.kind ~= M.Kind .. ".Diff"
        or report.version ~= M.Version or not valid(report.base)
        or not plain(report.functions) or report.functions.base ~= report.base.functions
        or not plain(report.by_key) or type(report.content) ~= "string" then
        return fail("unsupported", "a checked card diff against actual publications is required")
    end
    local state = report.base
    local loaded, lerr = discover(state.loaded_source, state)
    if not loaded then return nil, lerr end
    local candidate, cerr = discover(report.content, state, report.discovery)
    if not candidate then return nil, cerr end
    local result = {kind=M.Kind .. ".Coverage", version=M.Version, file=state.file,
        session_id=state.session_id, revision=state.revision, content=report.content,
        generation=report.discovery and report.discovery.common.candidate_generation,
        pending={},function_names={}}
    local function pending(kind, key, reason, point, previous)
        result.pending[#result.pending + 1] = {kind=kind, key=key, reason=reason,
            first=point and point.first, last=point and point.last,
            previous_first=previous and previous.first, previous_last=previous and previous.last}
    end
    local old_claims, new_claims = {}, {}
    local function claim(scan, claims, point, key)
        for index, statement in ipairs(scan.analysis.statements) do
            local tokens, last = scan.analysis.tokens, statement.tok.last
            while tokens[last] and tokens[last].value == ";" do last=last-1 end
            local token = tokens[last]
            if statement.source_range.first == point.first and token
                and token.pos + #token.value - 1 + scan.analysis.source_offset == point.last then
                if claims[index] then
                    return fail("ownership", "definition statement has multiple coverage owners", state, key)
                end
                claims[index] = key
                return true
            end
        end
        return fail("unsupported", "definition does not occupy a whole source statement", state, key)
    end
    local function function_claim(scan, claims, definition, key)
        local statement = scan.analysis.statements[definition.statement]
        if not statement then return fail("unsupported", "definition statement unavailable", state, key) end
        local last, tokens = statement.tok.last, scan.analysis.tokens
        while tokens[last] and tokens[last].value == ";" do last=last-1 end
        return claim(scan, claims, {first=statement.source_range.first,
            last=tokens[last].pos + #tokens[last].value - 1 + scan.analysis.source_offset}, key)
    end
    for _, name in ipairs(state.functions.names) do
        local key, item = "local:" .. name, report.functions.by_name[name]
        result.function_names[name]=true
        local old = loaded.scan.definitions[name]
        if not old or #old ~= 1 then return fail("ownership", "loaded function definition unavailable", state, key) end
        local ok, err = function_claim(loaded.scan, old_claims, old[1], key)
        if not ok then return nil, err end
        if item.blocked or item.changed then
            pending("function", key, item.blocked and item.blocked.message or "function definition not published")
        end
        -- Only a successfully prepared unique literal can claim its statement.
        -- Blocked/multiple/dynamic writes otherwise remain in the token remainder.
        if item.item then
            local definitions = candidate.scan.definitions[name]
            if not definitions or #definitions ~= 1
                or definitions[1].body ~= item.item.definition.body then
                return fail("ownership", "prepared function disagrees with candidate definition", state, key)
            end
            ok, err = function_claim(candidate.scan, new_claims, definitions[1], key)
            if not ok then return nil, err end
        end
    end
    for _, key in ipairs(state.order) do
        local unit, item = state.units[key], report.by_key[key]
        local old = loaded.descriptors[key]
        if not old then return fail("ownership", "loaded callback owner unavailable", state, key) end
        local source_slot = item.source_slot or unit.slot
        local newer = not item.pending and candidate.descriptors[key_of(unit.class_key, source_slot)]
        if item.pending then
            pending("identity", key, item.reason or "source has no proven safe published correspondence")
        end
        for _, name in ipairs(CALLBACKS) do
            local old_point = old.descriptor.callback_points and old.descriptor.callback_points[name]
            if old_point then
                local ok, err = claim(loaded.scan, old_claims, old_point, key .. ":" .. name)
                if not ok then return nil, err end
            end
            local cb = item.callbacks[name]
            if cb.changed then
                local point = newer and newer.descriptor.callback_points
                    and newer.descriptor.callback_points[name]
                pending("callback", key .. ":" .. name, "callback definition not published", point, old_point)
            end
            local point = newer and newer.descriptor.callback_points and newer.descriptor.callback_points[name]
            if point then
                if newer.descriptor.callbacks[name] ~= cb.body then
                    return fail("ownership", "callback disagrees with candidate definition", state, key)
                end
                local ok, err = claim(candidate.scan, new_claims, point, key .. ":" .. name)
                if not ok then return nil, err end
            end
        end
    end
    for _, row in ipairs(report.unowned or {}) do
        pending("identity", row.source_key .. ":" .. row.candidate_slot, row.reason,
            row.descriptor.callback_points and row.descriptor.callback_points.init)
    end
    result.before={scan=loaded.scan,claims=old_claims,
        structures=card_file_facts(state,loaded.scan,{}).structures}
    result.after={scan=candidate.scan,claims=new_claims,
        structures=card_file_facts(state,candidate.scan,{}).structures}
    return result
end

function M.Compare(state, content) return compare(state, content) end
---Complete FileMatch snapshot carrying this actual publication baseline in
---common. Class keys are NOT the per-card publication keys in this report.
---Invalid/incomplete snapshots refuse; no hidden Match or legacy fallback.
function M.CompareDiscovery(state, snapshot)
    if not plain(snapshot) or not plain(snapshot.common) then
        return fail("stale", "discovery published baseline disagrees", state)
    end
    return compare(state, snapshot.common.content, snapshot)
end

---Explicit new entry: never overload legacy Compare or infer a location.
---Fresh reads are supplied by trusted orchestration; they are not an I/O proof.
function M.CompareLocated(state, location, binding, capture, live)
    if not valid(state) then return fail("unsupported", "a valid card snapshot is required", state) end
    local checked, err = Target.CheckDiscovery(location, binding, capture, live)
    if not checked then return nil, err end
    if location.target.snapshot ~= state then
        return fail("stale", "located publication baseline disagrees", state)
    end
    return compare(state, location.content, location.discovery, location)
end
---Card-only file comparison. Does NOT gate other top-level effects.
---Production file callers must use FileApply.CompareCards before selecting.
---File correspondence remains a distinct permission scope from current-root.
function M.CompareFileLocated(state,location,capture,live)
    if not valid(state) then return fail("unsupported","a valid card snapshot is required",state) end
    local checked,err=Target.CheckFileDiscovery(location,capture,live)
    if not checked then return nil,err end
    if location.snapshot~=state then return fail("stale","file publication baseline disagrees",state) end
    return compare(state,location.content,location.discovery,nil,location)
end
---Select all individually safe roots, then build ONE aggregate. Singleton
---selections are read-only graph checks, never separate commits/versions.
function M.SelectFile(report)
    if not plain(report) or not plain(report.file_location) or not valid(report.base) then
        return fail("unsupported","file-located card report required")
    end
    local keys,names,blocked={},{},{}
    for _,key in ipairs(report.base.order) do
        local selected,err=M.Select(report,{key})
        if selected then keys[#keys+1]=key
        else blocked[#blocked+1]={key=key,reason=err.message,code=err.code} end
    end
    for _,name in ipairs(report.base.functions.names) do
        local selected,err=M.Select(report,{}, {name})
        if selected then names[#names+1]=name
        else blocked[#blocked+1]={key="local:"..name,reason=err.message,code=err.code} end
    end
    local selection,err=M.Select(report,keys,names)
    if not selection then return nil,err end
    selection.blocked=blocked
    return selection
end

return M
