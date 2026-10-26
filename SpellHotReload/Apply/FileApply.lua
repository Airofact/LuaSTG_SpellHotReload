--- Concrete file-Apply policy and post-publication accounting.
--- No candidate execution, publication, ACK, registration or restart here.
--- Each original owner supplies exact statement and actual-version evidence.
--- This module merges it, gates unknown effects and accounts for the remainder.
--- Exclusion, preparation and partial receipts never mean whole-file completion.
local Alignment=require("SpellHotReload.Source.StatementAlignment")
local Tree=require("SpellHotReload.Source.SyntaxTree")
local Source=require("SpellHotReload.Source.FileAnalysis")
local Files=require("SpellHotReload.Pipeline.FileVersions")
local M={}
local function dense(v)
    if type(v)~="table" or getmetatable(v)~=nil then return false end
    local count,max=0,0
    for k in next,v do
        if type(k)~="number" or k<1 or k>=math.huge or k~=math.floor(k) then return false end
        count=count+1;max=math.max(max,k)
    end
    return count==max
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
    local call=Tree.Match(ast,"call_statement")
    return call and Tree.IsName(call.callee,"Include") and #call.args==1
        and Tree.String(call.args[1])~=nil or false
end


-- Even excluded/claimed tokens must form one complete source partition.
local function partition(scan,state)
    if not Source.Validate(scan) then return fail("unsupported","complete shared source required",state) end
    local next_token=1
    for index,statement in ipairs(scan.analysis.statements) do
        if statement.tok.first~=next_token or statement.tok.last<statement.tok.first
            or statement.tok.last>#scan.analysis.tokens or not scan.bindings.statements[index]
            or not plain(scan.bindings.statements[index].visible) then
            return fail("unsupported","source token partition is incomplete",state)
        end
        next_token=statement.tok.last+1
    end
    if next_token~=#scan.analysis.tokens+1 then return fail("unsupported","source has unaccounted tokens",state) end
    return true
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
        local valid,err=partition(scan,state);if not valid then return nil,err end
        for index,statement in ipairs(scan.analysis.statements) do
            if not side.excluded[index] and not ignored_include(scan,index) then
                local pieces,visible={},{}
                local tokens,last=scan.analysis.tokens,Tree.ContentLast(statement.syntax)
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


-- Owner-returned whole-statement masks are operation-lifetime semantic evidence,
-- not a cache or a second publication ledger. Public code does not parse members.
function M.Collect(prepared)
    local op=plain(prepared) and prepared.operation
    local capture=plain(op) and op.capture
    if not plain(prepared) or prepared.kind~="SpellHotReload.Driver.PreparedDiscovery" or prepared.version~=2
        or not plain(op) or not Files.Validate(capture) or op.base_snapshot~=capture.snapshot
        or not dense(prepared.entries) or #prepared.entries~=#capture.snapshot.owners
        or not Source.Validate(op.source) then return fail("ownership","complete prepared original owners required") end
    local base=capture.snapshot
    local function side(source) return {scan=source,claims={},excluded={},structures={},binding_reads={},wiring=""} end
    local coverage={file=base.file,session_id=base.session_id,revision=base.revision,
        content=op.source.content,generation=op.generation,pending={},function_names={},
        before=side(base.entry.source),after=side(op.source)}
    local report={kind="SpellHotReload.FileApply.Report",version=2,base=base,operation=op,prepared=prepared,
        coverage=coverage,owner_evidence={},scopes={},needs_top_level=op.mode=="file"}
    report.file_facts={before=coverage.before,after=coverage.after}
    local function merge(target,source)
        if not plain(source) or source.scan~=target.scan or not plain(source.claims)
            or not plain(source.excluded) or not plain(source.structures) or not plain(source.binding_reads)
            or type(source.wiring)~="string" then return fail("ownership","complete same-source owner statement evidence required",base) end
        local ok,err=partition(source.scan,base);if not ok then return nil,err end
        for _,field in ipairs({"claims","excluded","structures","binding_reads"}) do
            for index,value in next,source[field] do
                if type(index)~="number" or index~=math.floor(index) or not source.scan.analysis.statements[index]
                    or (field=="claims" and (type(value)~="string" or value==""))
                    or (field~="claims" and value~=true) then return fail("ownership","invalid whole-statement owner evidence",base) end
                if field=="claims" and target.claims[index] then return fail("ownership","statement has multiple coverage owners",base) end
                target[field][index]=value
            end
        end
        -- Length framing prevents owners' wiring strings from cancelling out.
        target.wiring=target.wiring..#source.wiring..":"..source.wiring
        return true
    end
    for i,group in ipairs(base.owners) do
        local record=prepared.entries[i];local fragment=plain(record) and record.fragment
        local evidence=plain(fragment) and fragment.file_evidence
        if not plain(record) or record.owner~=group.owner or record.base_group~=group
            or not plain(fragment) or fragment.owner~=group.owner or fragment.base_group~=group or fragment.operation~=op
            or not plain(evidence) or evidence.kind~="SpellHotReload.FileCoverage" or evidence.version~=1
            or evidence.owner~=group.owner or evidence.base_group~=group or evidence.source~=op.source
            or evidence.initial_source~=base.entry.source or not dense(evidence.pending) or not plain(evidence.function_names)
            or type(evidence.requires_top_level)~="boolean" then return fail("ownership","all original owners must provide exact coverage",base) end
        local ok,err=merge(coverage.before,evidence.before);if not ok then return nil,err end
        ok,err=merge(coverage.after,evidence.after);if not ok then return nil,err end
        for name,value in next,evidence.function_names do
            if type(name)~="string" or value~=true or coverage.function_names[name] then
                return fail("ownership","duplicate or invalid function coverage name",base)
            end
            coverage.function_names[name]=true
        end
        for _,pending in ipairs(evidence.pending) do
            if not plain(pending) or type(pending.kind)~="string" or type(pending.key)~="string"
                or type(pending.reason)~="string" then return fail("ownership","explicit owner pending reason required",base) end
            local copy={};for key,value in next,pending do copy[key]=value end
            coverage.pending[#coverage.pending+1]=copy
        end
        if evidence.scope~=nil then
            if not plain(evidence.scope) or report.scopes[evidence.scope] then return fail("ownership","unique opaque owner proof scope required",base) end
            report.scopes[evidence.scope]=evidence
        elseif evidence.requires_top_level then return fail("ownership","file check requires an exact owner scope",base) end
        report.owner_evidence[i]=evidence
        report.needs_top_level=report.needs_top_level or evidence.requires_top_level
    end
    return report
end

-- File/Current orchestration uses this entry instead of bypassing file policy.
-- Current ordinary updates keep their existing scope; selected deletions add
-- the complete top-level proof without requiring every pending item to disappear.
function M.Prepare(driver,discovery,operation)
    if not plain(operation) or operation.file_proof~=nil then return fail("ownership","new file operation required") end
    local prepared,err=driver:PrepareDiscovery(discovery,operation)
    if not prepared then return nil,err end
    local report,why=M.Collect(prepared);if not report then return nil,why end
    if report.needs_top_level then
        local ok,problem=M.CheckTopLevel(report);if not ok then return nil,problem end
    end
    local base=operation.base_snapshot
    operation.file_proof={kind="SpellHotReload.FileApply.Proof",version=1,operation=operation,report=report,
        capture=operation.capture,snapshot=base,source=operation.source,generation=operation.generation,
        mode=operation.mode,entry=base.entry,anchor=base.anchor,file=base.file,session_id=base.session_id,
        needs_top_level=report.needs_top_level}
    return prepared,report
end
-- Accept the kernel's shallow sealed operation, while comparing frozen fields.
-- This check never parses/compiles source or treats an analysis hit as permission.
function M.CheckProof(operation,live)
    local proof=plain(operation) and operation.file_proof
    if not plain(proof) or proof.kind~="SpellHotReload.FileApply.Proof" or proof.version~=1
        or not plain(proof.report) or not Files.Validate(proof.capture) or not plain(proof.snapshot)
        or not dense(proof.snapshot.owners) or not plain(proof.report.prepared)
        or not dense(proof.report.prepared.entries)
        or #proof.report.prepared.entries~=#proof.snapshot.owners or not dense(proof.report.owner_evidence)
        or #proof.report.owner_evidence~=#proof.snapshot.owners
        or proof.report.operation~=proof.operation
        or operation.capture~=proof.capture or operation.base_snapshot~=proof.snapshot
        or proof.capture.snapshot~=proof.snapshot or operation.source~=proof.source
        or operation.generation~=proof.generation or operation.mode~=proof.mode
        or operation.entry~=proof.entry or operation.anchor~=proof.anchor or operation.file~=proof.file
        or operation.session_id~=proof.session_id or not Source.Validate(proof.source)
        or not plain(live) or live.capture~=proof.capture or live.snapshot~=proof.snapshot
        or live.entry~=proof.entry or live.session_id~=proof.session_id or live.content~=proof.source.content
        or live.generation~=proof.generation or live.released or live.poisoned then
        return fail("stale","complete file proof or fresh live scope changed")
    end
    for i,group in ipairs(proof.snapshot.owners) do
        local record=proof.report.prepared.entries[i]
        if not plain(record) or record.base_group~=group or not plain(record.fragment)
            or record.fragment.file_evidence~=proof.report.owner_evidence[i] then
            return fail("ownership","prepared file coverage changed",proof.snapshot)
        end
    end
    if proof.needs_top_level then return M.CheckTopLevel(proof.report) end
    return true
end
function M.CheckDeletions(operation,scope,live)
    local proof=plain(operation) and operation.file_proof
    local evidence=plain(proof) and plain(proof.report) and plain(proof.report.scopes) and proof.report.scopes[scope]
    if not plain(evidence) or evidence.scope~=scope or evidence.requires_top_level~=true or proof.needs_top_level~=true then
        return fail("ownership","selected deletion lacks complete original-owner file proof")
    end
    return M.CheckProof(operation,live)
end
-- The trusted orchestrator passes this wrapper to FileCommit's final refresh.
-- It reads NEW lifecycle/bytes, then checks file proof before final domain Guards.
function M.Refresh(operation,read)
    assert(type(read)=="function","trusted fresh read required")
    return function()
        local live,err=read();if not live then return nil,err end
        local ok,why=M.CheckProof(operation,live);if not ok then return nil,why end
        return live
    end
end

---Read-only full remainder against actual publications. Not a receipt, ACK,
---freshness proof or removal authority. Includes are outside reload scope,
---never executed and never represented as published definitions.
function M.Remaining(report)
    local evidence=plain(report) and report.coverage
    if not plain(report) or report.kind~="SpellHotReload.FileApply.Report" or report.version~=2
        or not plain(evidence) or not plain(report.operation) or not Files.Validate(report.operation.capture)
        or report.base~=report.operation.capture.snapshot then
        return fail("stale","remainder requires all-owner evidence against the actual snapshot")
    end
    local state=report.base
    local result={kind="SpellHotReload.FileApply.Remaining",version=2,
        file=evidence.file,session_id=evidence.session_id,revision=evidence.revision,
        content=evidence.content,generation=evidence.generation,pending={}}
    for _,item in ipairs(evidence.pending) do
        local copy={};for key,value in next,item do copy[key]=value end
        result.pending[#result.pending+1]=copy
    end
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
                for i=first,Tree.ContentLast(statement.syntax) do
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


-- Caller supplies NEW discovery/reconciliation against the current publication,
-- but the same FileAnalysis can be reused. Empty roots prepare only complete
-- actual read sets, never pending candidate closures. This path cannot commit.
function M.InspectFileRemainder(driver,discovery,operation,refresh)
    if not plain(operation) or operation.mode~="file" or not dense(operation.roots)
        or #operation.roots~=0 or operation.file_proof~=nil or type(refresh)~="function" then
        return fail("ownership","fresh file accounting operation with no publication roots required")
    end
    local prepared,err=driver:PrepareDiscovery(discovery,operation);if not prepared then return nil,err end
    local report,why=M.Collect(prepared);if not report then return nil,why end
    local model,merr=M.Remaining(report);if not model then return nil,merr end
    for _,record in ipairs(prepared.entries) do
        local f=record.fragment
        if #f.joins+#f.cell_writes+#f.raw_writes~=0 or f.proposed_group~=f.base_group then
            return fail("ownership","accounting owner attempted publication",report.base)
        end
    end
    local Guard=require("SpellHotReload.Apply.CommitCheck")
    local fragments={};for _,record in ipairs(prepared.entries) do fragments[#fragments+1]=record.fragment end
    local plan,perr=Guard.Seal(operation,fragments);if not plan then return nil,perr end
    local fresh,ferr=refresh();if not fresh then return nil,ferr end
    local ok,gerr=Guard.Check(plan,operation.capture,fresh);if not ok then return nil,gerr end
    local witness
    if model.complete then
        ok,gerr=M.CheckTopLevel(report);if not ok then return nil,gerr end
        witness={kind="SpellHotReload.FileApply.Witness",version=2,plan=plan,report=report,
            snapshot=operation.base_snapshot,content=operation.source.content,generation=operation.generation}
    end
    return model,witness,fresh
end
function M.CheckWitness(witness,capture,live)
    if not plain(witness) or witness.kind~="SpellHotReload.FileApply.Witness" or witness.version~=2
        or not Files.Validate(capture) or witness.snapshot~=capture.snapshot
        or not plain(witness.plan) or witness.plan.base_snapshot~=witness.snapshot
        or witness.plan.proposed_snapshot~=witness.snapshot or not dense(witness.plan.joins)
        or not dense(witness.plan.journal) or #witness.plan.joins+#witness.plan.journal~=0
        or not plain(live) or live.content~=witness.content or live.generation~=witness.generation then
        return fail("stale","actual no-op completion witness changed")
    end
    local model,err=M.Remaining(witness.report)
    if not model then return nil,err end
    if not model.complete then return fail("stale","whole-file remainder is no longer complete",capture.snapshot) end
    return require("SpellHotReload.Apply.CommitCheck").Check(witness.plan,capture,live)
end
return M
