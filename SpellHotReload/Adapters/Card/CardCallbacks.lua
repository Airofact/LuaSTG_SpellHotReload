-- Match one generated card definition from the shared cursor. No class-window
-- scanning, callback replay, source compilation or candidate execution.
local Source=require("SpellHotReload.Source.FileAnalysis")
local Pattern=require("SpellHotReload.Adapters.Card.CardSyntax")
local M={}
local allowed={};for _,name in ipairs({"before","init","frame","render","beforedel","del","after"}) do allowed[name]=true end
local function fail(message) return nil,{code="unsupported",message=message} end
local function descriptor(Tree,expression,visible)
    local kind,call=Pattern.Constructor(Tree,expression)
    return {kind=kind or "other",name=kind and (Tree.String(call.args[1]) or "") or "",
        constructor=Tree.Signature(expression),callbacks={},callback_points={},callback_syntax={},callback_signatures={},
        locals=visible or {},perform=""}
end
function M.Match(cursor,source)
    local Tree=source.analysis.syntax;local start=cursor:Mark();local first=cursor:Peek()
    local target,rhs=Tree.SingleAssignment(first.syntax)
    if not Tree.IsName(target,"_tmp_sc") or not Pattern.Constructor(Tree,rhs) then return nil end
    local desc=descriptor(Tree,rhs,Source.VisibleBefore(source,start));desc.first=start
    cursor:Take()
    while not cursor:AtEnd() do
        local statement=cursor:Peek();local ast=statement.syntax
        local callback,fn,method=Pattern.Callback(Tree,ast)
        local target,value=Tree.SingleAssignment(ast)
        local member=Tree.Match(target,"member")
        local assignment=Tree.Match(ast,"assignment")
        local call=Tree.Match(ast,"call_statement")
        if assignment and (#assignment.targets~=1 or #assignment.values~=1) then
            for _,written in ipairs(assignment.targets) do
                local part=Tree.Match(written,"member") or Tree.Match(written,"index")
                if Tree.IsName(written,"_tmp_sc") or part and Tree.IsName(part.base,"_tmp_sc") then
                    return fail("multi-target or multi-value card assignment")
                end
            end
        end
        if callback then
            if not allowed[callback] then return fail("unsupported card callback: "..callback) end
            if desc.callbacks[callback] then return fail("duplicate card callback: "..callback) end
            desc.callbacks[callback]=Tree.FunctionSource(fn,method)
            desc.callback_syntax[callback]=fn
            desc.callback_signatures[callback]="literal|"..Tree.FunctionSignature(fn,method)
            local range,err=Source.ByteRange(source,fn,"function");if not range then return nil,err end
            desc.callback_points[callback]={first=statement.source_range.first,last=range.last}
        elseif member and Tree.IsName(member.base,"_tmp_sc") then
            if member.name~="perform" then return fail("unsupported card assignment: "..member.name) end
            if desc.perform~="" then return fail("duplicate card perform assignment") end
            desc.perform=Tree.Text(value)
            local literal=Tree.Match(value,"literal")
            if literal and literal.category=="boolean" then desc.perform_point=statement.source_range end
        elseif call and Tree.Path(call.callee)=="table.insert" and #call.args==2
            and Pattern.CardList(Tree,call.args[1]) and Tree.IsName(call.args[2],"_tmp_sc") then
            -- Registration belongs to this card; layout/slot follows separately.
        elseif call and Tree.Path(call.callee)=="table.insert" and #call.args==2 and Tree.IsName(call.args[1],"_sc_table") then
            local record=Tree.Match(call.args[2],"table")
            if not record or #record.fields~=5 or not record.fields[3].array
                or not Tree.IsName(record.fields[3].value,"_tmp_sc") then break end
        else break end
        cursor:Take()
    end
    desc.last=cursor:Mark()-1
    return desc
end

-- Compute registration relations from accepted single-card descriptors. This
-- interprets list wiring once; it never reads callback bodies or creates units.
function M.Layout(source,units)
    local Tree=source.analysis.syntax
    local starts,covered={},{}
    for _,unit in ipairs(units) do
        local desc=unit.context.descriptor
        starts[desc.first]=unit
        unit.context.placements={}
        for i=desc.first,desc.last do covered[i]=true end
    end
    local classes,by_class,current={},{},nil
    local function class(key,index)
        local row=by_class[key]
        if not row then row={class_key=key,layout={},first=index};by_class[key]=row;classes[#classes+1]=row end
        return row
    end
    for index,statement in ipairs(source.analysis.statements) do
        local ast=statement.syntax;local target,value=Tree.SingleAssignment(ast)
        if starts[index] then current=starts[index].context.descriptor;current.unit=starts[index]
        elseif Tree.IsName(target,"_tmp_sc") then current=nil end
        local key=Pattern.CardList(Tree,target)
        local list=Tree.Match(value,"table")
        local call=Tree.Match(ast,"call_statement")
        if key and list then
            if key=="" then return fail("card list class key is empty") end
            local row=class(key,index);local layout={}
            for _,field in ipairs(list.fields) do
                if not field.array then return fail("unsupported keyed class card list") end
                if Tree.IsName(field.value,"_tmp_sc") then
                    if not current then return fail("card list reuses an unknown _tmp_sc") end
                    layout[#layout+1]=current
                else layout[#layout+1]=descriptor(Tree,field.value) end
            end
            row.layout=layout
        elseif call and Tree.IsName(call.callee,"_BOSS_ESCAPE") then
            local key=Tree.String(call.args[1])
            if #call.args~=4 or not key or Source.ResolveLocal(source,index,"_BOSS_ESCAPE") then
                return fail("literal unshadowed _BOSS_ESCAPE and four arguments required")
            end
            local row=by_class[key];if not row then return fail("escape registration before class card list") end
            for slot=1,2 do row.layout[#row.layout+1]={kind="other",name="",constructor=Tree.Signature(call.node)..":escape-slot:"..slot,
                callbacks={},locals={},perform=""} end
        elseif call and Tree.Path(call.callee)=="table.insert" and #call.args==2 and Pattern.CardList(Tree,call.args[1]) then
            local key=Pattern.CardList(Tree,call.args[1]);local row=by_class[key]
            if not row then return fail("card registration before class card list") end
            row.layout[#row.layout+1]=Tree.IsName(call.args[2],"_tmp_sc") and current or descriptor(Tree,call.args[2])
        end
        if Pattern.Callback(Tree,ast) and not covered[index] then
            return fail("card callback is outside a matched single-card definition")
        end
    end
    for _,row in ipairs(classes) do for slot,desc in ipairs(row.layout) do
        if desc.unit then
            local placements=desc.unit.context.placements
            placements[#placements+1]={class_key=row.class_key,slot=slot}
        end
    end end
    for _,unit in ipairs(units) do
        local placements=unit.context.placements
        if #placements==1 then unit.context.class_key=placements[1].class_key;unit.context.slot=placements[1].slot end
    end
    return {source=source,carrier="card",units=units,classes=classes,by_class=by_class}
end
return M
