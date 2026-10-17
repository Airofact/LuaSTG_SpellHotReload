--- Concrete file-Apply policy and post-publication accounting.
--- No candidate execution, publication, ACK, registration or restart here.
--- CardVersions supplies only its owned statement/binding evidence; this file
--- owns other top-level changes, Include exclusion and whole-file completion.
local Alignment=require("SpellHotReload.Source.StatementAlignment")
local Tree=require("SpellHotReload.Source.SyntaxTree")
local M={}
local function message(err)
    return type(err)=="table" and err.message or tostring(err)
end
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function fail(code,message,state)
    return nil,{phase="analyze",code=code,message=message,
        file=plain(state) and state.file or nil}
end
-- This exclusion is never evidence that the included file has been loaded.
local function ignored_include(scan,index)
    local statement=scan.analysis.statements[index]
    local record=scan.bindings.statements[index]
    if not statement or not record or not record.visible or record.unparsed
        or record.visible.Include then return false end
    local ast=statement.syntax
    local call=ast.kind=="call_statement" and ast.expression
    return call and Tree.IsName(call.callee,"Include") and #call.args==1
        and call.args[1].kind=="literal" and call.args[1].literal_kind=="string" or false
end

---Whole-file preflight. Adapter exclusions do NOT mean those bytes were
---published; only the separate coverage/remaining path can establish completion.
function M.CheckTopLevel(report)
    local facts=plain(report) and report.file_facts
    local state=plain(report) and report.base
    if not plain(state) or not plain(facts) or not plain(facts.before) or not plain(facts.after) then
        return fail("unsupported","file Apply requires complete adapter evidence",state)
    end
    local function residual(side)
        local scan,rows=side.scan,{}
        if not plain(scan) or not plain(side.excluded) or not plain(side.binding_reads)
            or type(side.wiring)~="string" then
            return fail("unsupported","file Apply statement evidence unavailable",state)
        end
        for index,statement in ipairs(scan.analysis.statements) do
            if not side.excluded[index] and not ignored_include(scan,index) then
                local pieces,visible={},{}
                local tokens,last=scan.analysis.tokens,statement.syntax.content_last
                for i=statement.tok.first,last do
                    pieces[#pieces+1]=tokens[i].kind..":"..#tokens[i].value..":"..tokens[i].value
                end
                for name in next,scan.bindings.statements[index].visible do visible[#visible+1]=name end
                table.sort(visible)
                rows[#rows+1]={signature=table.concat(pieces,"|").."@"..table.concat(visible,","),
                    first=statement.source_range.first,last=statement.source_range.last,
                    binding_read=side.binding_reads[index]}
            end
        end
        return rows
    end
    local before,berr=residual(facts.before)
    if not before then return nil,berr end
    local after,aerr=residual(facts.after)
    if not after then return nil,aerr end
    local aligned=Alignment.Compare(before,after)
    if not aligned.equal then
        local change=aligned.changes[1]
        local point=change.after[1] or change.before[1]
        return fail("unsupported",string.format("unbounded top-level change at bytes %d-%d; restart required",
            point.first,point.last),state)
    end
    for _,pair in ipairs(aligned.matches) do
        if facts.before.wiring~=facts.after.wiring and (pair.before.binding_read or pair.after.binding_read) then
            return fail("unsupported",string.format("unbounded pending wiring binding at bytes %d-%d; restart required",
                pair.after.first,pair.after.last),state)
        end
    end
    return true
end

---Production file planning entry: Card proves its targets/bindings, then the
---file policy gates all unclaimed effects BEFORE selection or commit.
function M.CompareCards(state,location,capture,live)
    local report,err=require("SpellHotReload.Adapters.Card.CardVersions").CompareFileLocated(state,location,capture,live)
    if not report then return nil,err end
    local safe,why=M.CheckTopLevel(report)
    if not safe then return nil,why end
    return report
end

---Read-only full remainder against actual publications. Not a receipt, ACK,
---freshness proof or removal authority. Includes are outside reload scope,
---never executed and never represented as published definitions.
function M.Remaining(report)
    local evidence,err=require("SpellHotReload.Adapters.Card.CardVersions").Coverage(report)
    if not evidence then return nil,err end
    local state=report.base
    local result={kind="SpellHotReload.FileApply.Remaining",version=1,
        file=evidence.file,session_id=evidence.session_id,revision=evidence.revision,
        content=evidence.content,generation=evidence.generation,pending=evidence.pending}
    local function pending(kind,key,reason,point,previous)
        result.pending[#result.pending+1]={kind=kind,key=key,reason=reason,
            first=point and point.first,last=point and point.last,
            previous_first=previous and previous.first,previous_last=previous and previous.last,
            label=point and point.label,line=point and point.line,
            previous_label=previous and previous.label,previous_line=previous and previous.line}
    end
    local function residual(scan, claims, structures)
        local rows, declarations, labels, next_token = {}, {}, {}, 1
        -- Diagnostic names from the existing IR; never claim or ignore a statement.
        for _, node in ipairs(scan.analysis.nodes) do
            labels[node.tok.first] = labels[node.tok.first] or node.path or node.name or node.callee
        end
        for _, declaration in ipairs(scan.bindings.declarations) do
            if not evidence.function_names[declaration.name] then
                declarations[declaration.statement] = declaration.name
            end
        end
        for index, statement in ipairs(scan.analysis.statements) do
            local tokens, first, last = scan.analysis.tokens, statement.tok.first, statement.tok.last
            -- Every lexer token must belong to one whole statement, claimed or
            -- retained. An analysis gap/overlap cannot silently count as coverage.
            if first ~= next_token or last < first or last > #tokens then
                return fail("unsupported", "source token partition is incomplete", state)
            end
            next_token = last + 1
            if not claims[index] and not ignored_include(scan,index) then
                local pieces = {}
                for i=first,statement.syntax.content_last do
                    local token=tokens[i]
                    pieces[#pieces+1]=token.kind .. ":" .. #token.value .. ":" .. token.value
                end
                if #pieces > 0 then
                    local visible = {}
                    for name in next, scan.bindings.statements[index].visible do visible[#visible+1]=name end
                    table.sort(visible)
                    local kind = declarations[index] and "initializer" or "unknown"
                    -- Classification is diagnostic only: these tokens are NEVER
                    -- discarded even if they match the safe-wiring grammar.
                    if structures[index] then
                        kind = "structure"
                    end
                    rows[#rows+1]={signature=table.concat(pieces,"|") .. "@" .. table.concat(visible,","),
                        kind=kind, key=declarations[index] and ("local:" .. declarations[index]) or ("file:" .. state.file),
                        first=statement.source_range.first,last=statement.source_range.last,
                        label=labels[first],line=statement.line}
                end
            end
        end
        if next_token ~= #scan.analysis.tokens + 1 then
            return fail("unsupported", "source has unaccounted tokens", state)
        end
        return rows
    end
    local before, berr = residual(evidence.before.scan,evidence.before.claims,evidence.before.structures)
    if not before then return nil, berr end
    local after, aerr = residual(evidence.after.scan,evidence.after.claims,evidence.after.structures)
    if not after then return nil, aerr end
    local aligned=Alignment.Compare(before,after)
    for _,change in ipairs(aligned.changes) do
        -- Pairing changed rows by index would invent correspondence. Each side
        -- keeps its own byte evidence; adapters own semantic updates/deletions.
        for _,b in ipairs(change.after) do
            local reason=b.kind=="initializer" and "state initializer retained; restart game to adopt"
                or (b.kind=="structure" and "constructor/name/list/registration retained; restart game to adopt"
                    or "top-level change not published or not confirmed; restart game to adopt")
            pending(b.kind,b.key,reason,b,nil)
        end
        for _,a in ipairs(change.before) do
            pending(a.kind,a.key,"previous top-level statement not confirmed in candidate; restart game to adopt",nil,a)
        end
    end
    result.alignment={ambiguous=aligned.ambiguous,reordered=aligned.reordered}
    result.complete = #result.pending == 0
    return result
end

---Post-receipt file accounting, shared by Current and file Apply. Analyze the
---actual installed snapshot, not Next or the old prepared selection. A complete
---result also carries a checked no-op read witness for cheap watcher validation.
---No commit, join, write, cache flush, registration or restart occurs here.
function M.InspectFileRemainder(capture, discovery, live, refresh)
    local Cards = require("SpellHotReload.Adapters.Card.CardVersions")
    local Target = require("SpellHotReload.Adapters.Card.CardTarget")
    local Guard = require("SpellHotReload.Apply.CommitCheck")
    local base = capture.snapshot
    local location, lerr = Target.LocateFileDiscovery(discovery.snapshot,capture,live)
    if not location then return nil, "correspondence: " .. message(lerr) end
    local report, rerr = M.CompareCards(base,location,capture,live)
    if not report then return nil, "compare: " .. message(rerr) end
    local model, merr = M.Remaining(report)
    if not model then return nil, "remainder: " .. message(merr) end
    local selection, serr = Cards.SelectFile(report)
    if not selection then return nil, "read witness: " .. message(serr) end
    if model.complete and (#selection.joins>0 or #selection.writes>0 or #selection.publications>0) then
        return nil, "complete remainder disagrees with publication actions"
    end
    local fresh, ferr = refresh()
    if not fresh then return nil, "freshness: " .. message(ferr) end
    local checked, cerr = Guard.Check(selection,capture,fresh)
    if not checked then return nil, "live reads: " .. message(cerr) end
    return model, selection, fresh
end

return M
