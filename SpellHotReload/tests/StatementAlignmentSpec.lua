-- Source-order evidence. No runtime owner is inferred from a signature.
local M={}
function M.run()
    local Alignment=require("SpellHotReload.Source.StatementAlignment")
    local passed,failed,failures=0,0,{}
    local function check(v,label) if v then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end end
    local function eq(a,b,label) check(a==b,label..": "..tostring(a).." ~= "..tostring(b)) end
    local function rows(values) local r={};for i,v in ipairs(values) do r[i]={signature=v,first=i,last=i} end;return r end
    local function compare(a,b) return Alignment.Compare(rows(a),rows(b)) end
    local r=compare({"a","b","c"},{"new","a","b","c"})
    eq(r.equal,false,"insert differs");eq(#r.changes,1,"no shifted cascade")
    eq(r.changes[1].kind,"insert","insert explicit");eq(r.changes[1].after[1].signature,"new","actual inserted row")
    eq(#r.matches,3,"unchanged suffix aligned")
    r=compare({"a","remove","b"},{"a","b"})
    eq(#r.changes,1,"single deletion");eq(r.changes[1].kind,"delete","deletion explicit")
    r=compare({"a","x","b"},{"a","y","b"})
    eq(#r.changes,1,"replacement region");eq(r.changes[1].before[1].signature,"x","old evidence")
    eq(r.changes[1].after[1].signature,"y","new evidence")
    r=compare({"a","b","c"},{"b","a","c"})
    eq(r.equal,false,"side-effect reorder never equal");eq(r.reordered,true,"reordered evidence")
    r=compare({"a","x","x","b"},{"a","x","b"})
    eq(r.equal,false,"duplicate count differs");eq(r.ambiguous,true,"no guessed duplicate owner")
    eq(#r.matches,2,"only unique anchors match changed duplicate region")
    eq(r.reordered,false,"duplicate count change is not proof of reordering")
    r=compare({"x","x"},{"x","x"})
    eq(r.equal,true,"equal repeated sequence is equal source evidence")
    eq(r.matches[1].owner,nil,"no runtime identity")
    eq(compare({},{}).equal,true,"empty equality")
    eq(compare({}, {"x"}).changes[1].kind,"insert","zero old rows")
    eq(compare({"x"},{}).changes[1].kind,"delete","zero new rows")
    local before,after={},{}
    for i=1,12000 do before[i]={signature=tostring(i),first=i,last=i};after[i]=before[i] end
    table.insert(after,6000,{signature="inserted",first=5999.5,last=5999.5})
    r=Alignment.Compare(before,after)
    eq(#r.changes,1,"large input sparse insert");eq(#r.matches,12000,"large input unchanged rows")
    print(string.format("StatementAlignmentSpec: %d passed / %d failed",passed,failed))
    for _,why in ipairs(failures) do print("  FAIL "..why) end
    return {passed=passed,failed=failed}
end
return M
