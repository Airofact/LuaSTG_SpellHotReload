-- Card-owned generated-code patterns over the public syntax query contract.
-- No parser layouts, source compilation, binding proof or publication permission.
local Tree=require("SpellHotReload.Source.SyntaxTree")
local M={}
function M.ClassKey(node)
    local index=Tree.Match(node,"index")
    if index and Tree.IsName(index.base,"_editor_class") then return Tree.String(index.key) end
end
function M.CardList(node)
    local member=Tree.Match(node,"member")
    if member and member.separator=="." and member.name=="cards" then return M.ClassKey(member.base) end
end
function M.Constructor(node)
    local call=Tree.Match(node,"call")
    if not call or call.method then return nil end
    local target=Tree.Match(call.callee,"member")
    if not target or target.name~="New" or target.separator~="." then return nil end
    local owner=Tree.Match(target.base,"member")
    if owner and owner.separator=="." and Tree.IsName(owner.base,"boss") then return owner.name,call end
end
function M.Callback(node)
    local definition=Tree.Match(node,"definition")
    local target=definition and Tree.Match(definition.target,"member")
    if target and Tree.IsName(target.base,"_tmp_sc") then
        return target.name,definition.fn,definition.method
    end
end
return M
