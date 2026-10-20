-- Card-only layout interpretation of one validated common FileAnalysis.
-- No full-source compilation/parsing here and no fallback analysis path.
local Source=require("SpellHotReload.Source.FileAnalysis")
local Tree=require("SpellHotReload.Source.SyntaxTree")
local M={}
local allowed={}
for _,name in ipairs({"before","init","frame","render","beforedel","del","after"}) do allowed[name]=true end
function M.Read(source,class_key)
    local valid,err=Source.Validate(source)
    if not valid then return nil,err end
    if type(class_key)~="string" or class_key=="" then return nil,"class key required" end
    local analysis=source.analysis
    local offset=analysis.source_offset
    local tokens=analysis.tokens
    local function descriptor(expression,visible)
        return {kind=Tree.Constructor(expression) or "other",
            name=Tree.Constructor(expression) and (Tree.String(expression.args[1]) or "") or "",
            constructor=Tree.Signature(expression,tokens),callbacks={},callback_points={},callback_syntax={},callback_signatures={},
            locals=visible or {},perform=""}
    end
    local layout,locals,pending,held={},{},nil,nil
    local found=false
    for _,statement in ipairs(analysis.statements) do
        local ast=statement.syntax
        if ast.kind=="local" or ast.kind=="local_function" then
            for _,binding in ipairs(ast.names) do locals[binding.name]=true end
        end
        local target,rhs=Tree.SingleAssignment(ast)
        local list_key=Tree.CardList(target)
        local call=ast.kind=="call_statement" and ast.expression or nil
        local callback,fn,method=Tree.Callback(ast)
        if pending and ast.kind=="assign" and (#ast.targets~=1 or #ast.values~=1) then
            for _,written in ipairs(ast.targets) do
                if Tree.IsName(written,"_tmp_sc") or ((written.kind=="member" or written.kind=="index") and Tree.IsName(written.base,"_tmp_sc")) then
                    return nil,"unsupported multi-target or multi-value card assignment"
                end
            end
        end
        if list_key==class_key and rhs.kind=="table" then
            if #rhs.fields==0 and found then return nil,"duplicate class card list" end
            found=true;local rebuilt={}
            for _,field in ipairs(rhs.fields) do
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
                    layout[#layout+1]={kind="other",name="",constructor=Tree.Signature(call,tokens)..":escape-slot:"..slot,
                        callbacks={},locals={},perform=""}
                end
            end
        elseif Tree.IsName(target,"_tmp_sc") then
            pending,held=nil,nil
            if Tree.Constructor(rhs) then
                local visible={};for name in pairs(locals) do visible[name]=true end
                pending=descriptor(rhs,visible);held=pending
            end
        elseif pending and callback then
            if not allowed[callback] then return nil,"unsupported card callback: "..callback end
            if pending.callbacks[callback] then return nil,"duplicate card callback: "..callback end
            pending.callbacks[callback]=Tree.FunctionSource(fn,analysis,method)
            pending.callback_syntax[callback]=fn
            pending.callback_signatures[callback]="literal|"..Tree.FunctionSignature(fn,tokens,method)
            pending.callback_points[callback]={first=tokens[ast.first].pos+offset,
                last=tokens[fn.last].pos+#tokens[fn.last].value-1+offset}
        elseif pending and target and target.kind=="member" and Tree.IsName(target.base,"_tmp_sc") then
            if target.name=="perform" then
                if pending.perform~="" then return nil,"duplicate card perform assignment" end
                pending.perform=Tree.Text(rhs,analysis)
                -- Only a single boolean assignment attached to this constructor
                -- is generated metadata. Other expressions remain unmodeled effects.
                if rhs.kind=="literal" and rhs.literal_kind=="boolean" then
                    pending.perform_point={first=statement.source_range.first,last=statement.source_range.last}
                end
            else return nil,"unsupported card assignment: "..target.name end
        elseif call and Tree.Path(call.callee)=="table.insert" and #call.args==2
            and Tree.CardList(call.args[1])==class_key then
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
