-- Card-owned generated-code patterns over the public syntax query contract.
-- No parser layouts, source compilation, binding proof or publication permission.
local M={}
function M.ClassKey(Tree,node)
    local index=Tree.Match(node,"index")
    if index and Tree.IsName(index.base,"_editor_class") then return Tree.String(index.key) end
end
function M.CardList(Tree,node)
    local member=Tree.Match(node,"member")
    if member and member.separator=="." and member.name=="cards" then return M.ClassKey(Tree,member.base) end
end
function M.Constructor(Tree,node)
    local call=Tree.Match(node,"call")
    if not call or call.method then return nil end
    local target=Tree.Match(call.callee,"member")
    if not target or target.name~="New" or target.separator~="." then return nil end
    local owner=Tree.Match(target.base,"member")
    if owner and owner.separator=="." and Tree.IsName(owner.base,"boss") then return owner.name,call end
end
-- Expression-level target recognition only; callback policy stays in Card.
function M.TempField(Tree,target)
    local member=Tree.Match(target,"member")
    if member and Tree.IsName(member.base,"_tmp_sc") then return member.name end
end
function M.Callback(Tree,node)
    local definition=Tree.Match(node,"definition")
    local name=definition and M.TempField(Tree,definition.target)
    if name then return name,definition.fn,definition.method end
end
return M
