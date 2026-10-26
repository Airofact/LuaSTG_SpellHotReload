-- Card-only layout interpretation of one validated common FileAnalysis.
-- Syntax captures are public facts; no parser fields or fallback analysis.
local Source=require("SpellHotReload.Source.FileAnalysis")
local Tree=require("SpellHotReload.Source.SyntaxTree")
local CardSyntax=require("SpellHotReload.Adapters.Card.CardSyntax")
local M={}
local allowed={}
for _,name in ipairs({"before","init","frame","render","beforedel","del","after"}) do allowed[name]=true end
function M.Read(source,class_key)
    local valid,err=Source.Validate(source)
    if not valid then return nil,err end
    if type(class_key)~="string" or class_key=="" then return nil,"class key required" end
    local analysis=source.analysis
    local function descriptor(expression,visible)
        local kind,call=CardSyntax.Constructor(expression)
        return {kind=kind or "other",name=kind and (Tree.String(call.args[1]) or "") or "",
            constructor=Tree.Signature(expression),callbacks={},callback_points={},callback_syntax={},callback_signatures={},
            locals=visible or {},perform=""}
    end
    local layout,locals,pending,held={},{},nil,nil
    local found=false
    for _,statement in ipairs(analysis.statements) do
        local ast=statement.syntax
        local declaration=Tree.Match(ast,"declaration")
        if declaration then
            for _,binding in ipairs(declaration.names) do locals[Tree.Identifier(binding)]=true end
        end
        local target,rhs=Tree.SingleAssignment(ast)
        local list_key=CardSyntax.CardList(target)
        local call=Tree.Match(ast,"call_statement")
        local callback,fn,method=CardSyntax.Callback(ast)
        local assignment=Tree.Match(ast,"assignment")
        if pending and assignment and (#assignment.targets~=1 or #assignment.values~=1) then
            for _,written in ipairs(assignment.targets) do
                local member=Tree.Match(written,"member") or Tree.Match(written,"index")
                if Tree.IsName(written,"_tmp_sc") or (member and Tree.IsName(member.base,"_tmp_sc")) then
                    return nil,"unsupported multi-target or multi-value card assignment"
                end
            end
        end
        local list=Tree.Match(rhs,"table")
        local member=Tree.Match(target,"member")
        if list_key==class_key and list then
            if #list.fields==0 and found then return nil,"duplicate class card list" end
            found=true;local rebuilt={}
            for _,field in ipairs(list.fields) do
                if not field.array then return nil,"unsupported keyed class card list" end
                if Tree.IsName(field.value,"_tmp_sc") then
                    if not held then return nil,"card list reuses an unknown _tmp_sc" end
                    rebuilt[#rebuilt+1]=held
                else rebuilt[#rebuilt+1]=descriptor(field.value) end
            end
            layout=rebuilt
        elseif call and Tree.IsName(call.callee,"_BOSS_ESCAPE") then
            local key=Tree.String(call.args[1])
            if #call.args~=4 or not key or locals._BOSS_ESCAPE then
                return nil,"unsupported _BOSS_ESCAPE call; literal class and four arguments required"
            end
            if key==class_key then
                if not found then return nil,"escape registration before class card list" end
                for slot=1,2 do
                    layout[#layout+1]={kind="other",name="",constructor=Tree.Signature(call.node)..":escape-slot:"..slot,
                        callbacks={},locals={},perform=""}
                end
            end
        elseif Tree.IsName(target,"_tmp_sc") then
            pending,held=nil,nil
            if CardSyntax.Constructor(rhs) then
                local visible={};for name in pairs(locals) do visible[name]=true end
                pending=descriptor(rhs,visible);held=pending
            end
        elseif pending and callback then
            if not allowed[callback] then return nil,"unsupported card callback: "..callback end
            if pending.callbacks[callback] then return nil,"duplicate card callback: "..callback end
            pending.callbacks[callback]=Tree.FunctionSource(fn,method)
            pending.callback_syntax[callback]=fn
            pending.callback_signatures[callback]="literal|"..Tree.FunctionSignature(fn,method)
            local range,range_error=Source.ByteRange(source,fn)
            if not range then return nil,range_error end
            pending.callback_points[callback]={first=statement.source_range.first,last=range.last}
        elseif pending and member and Tree.IsName(member.base,"_tmp_sc") then
            if member.name=="perform" then
                if pending.perform~="" then return nil,"duplicate card perform assignment" end
                pending.perform=Tree.Text(rhs)
                -- Only attached boolean metadata is covered as generated wiring.
                local literal=Tree.Match(rhs,"literal")
                if literal and literal.category=="boolean" then
                    pending.perform_point={first=statement.source_range.first,last=statement.source_range.last}
                end
            else return nil,"unsupported card assignment: "..member.name end
        elseif call and Tree.Path(call.callee)=="table.insert" and #call.args==2
            and CardSyntax.CardList(call.args[1])==class_key then
            if not found then return nil,"card registration before class card list" end
            if pending and Tree.IsName(call.args[2],"_tmp_sc") then layout[#layout+1]=pending
            else layout[#layout+1]=descriptor(call.args[2]) end
            pending=nil
        end
    end
    if not found then return nil,"class not found" end
    return layout
end
return M
