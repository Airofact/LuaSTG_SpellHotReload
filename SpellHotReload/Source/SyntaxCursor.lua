-- One controlled position over an existing syntax-item sequence.
-- Source lifetime and lexical context stay with the caller's complete snapshot.
local M={}
function M.New(items)
    assert(type(items)=="table","syntax items required")
    local position=1
    local methods={}
    function methods:Peek(offset) return items[position+(offset or 0)] end
    function methods:Take()
        local item=items[position]
        assert(item~=nil,"cannot consume past syntax end")
        position=position+1
        return item
    end
    function methods:Mark() return position end
    function methods:Reset(mark)
        assert(type(mark)=="number" and mark==math.floor(mark)
            and mark>=1 and mark<=#items+1,"invalid syntax position")
        position=mark
    end
    function methods:AtEnd() return position>#items end
    return setmetatable({}, {__index=methods,
        __newindex=function() error("syntax cursor is read-only; use its methods",2) end,
        __metatable=false})
end
return M
