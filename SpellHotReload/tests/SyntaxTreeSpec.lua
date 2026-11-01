-- Shared structural evidence and downstream reuse, with no runtime ownership claims.
local M={}
function M.run()
    local IR=require("SpellHotReload.Source.TopLevelIR")
    local Source=require("SpellHotReload.Source.FileAnalysis")
    local Syntax=require("SpellHotReload.Source.SyntaxTree")
    local Cards=require("SpellHotReload.Adapters.Card.Card")
    local Driver=require("SpellHotReload.Pipeline.Driver")
    local FileMatch=require("SpellHotReload.Pipeline.FileMatch")
    local Local=require("SpellHotReload.Adapters.Local.Local")
    local ClassAdapter=require("SpellHotReload.Adapters.Class.Class")
    local function discover(facts)
        local d=Driver.New();assert(d:RegisterDiscovery(Local));assert(d:RegisterDiscovery(ClassAdapter));assert(d:RegisterDiscovery(Cards))
        local found,err=d:Discover("SyntaxTree_Boss.lua",facts,{})
        if not found then return nil,err end
        return FileMatch.ForOwner(found.snapshot,Cards,facts)
    end
    local Compose=require("SpellHotReload.Source.Compose")
    local passed=0
    local function eq(a,b,label) assert(a==b,label..": "..tostring(a).." ~= "..tostring(b));passed=passed+1 end
    local function analyze(source)
        local nodes,err,analysis=IR.Analyze(source);assert(nodes,err);return analysis
    end
    local Impl=require("SpellHotReload.Source.SyntaxTreeImpl.TreeSitter")
    eq(Syntax,Impl,"public syntax entry is the selected implementation table")
    eq(Syntax.Parse,Impl.Parse,"public parse retains implementation function identity")
    local a=analyze("local a,b=1,2; local function f(x,...) local b={...};return function(y) return b[y],a end end; function T:m(n) return self,n end; T[k]=f(a); Include'path'")
    local Tree=a.syntax
    eq(Tree.Is(Tree.root,"chunk"),true,"root kind")
    local statements=Tree.Statements(Tree.root)
    eq(a.statements[1].syntax,statements[1],"shared statement identity")
    eq(#statements,5,"statement count")
    local first=assert(Tree.Match(statements[1],"declaration"))
    eq(first.self_visible,false,"plain local declaration")
    eq(#first.names,2,"binding list")
    eq(Tree.Is(first.names[1],"binding"),true,"declaration distinct from name read")
    eq(Tree.Match(first.values[2],"literal").category,"number","numeric literal category")
    local fn=Tree.Match(statements[2],"definition").fn
    local function_info=Tree.Match(fn,"function")
    eq(Tree.Identifier(function_info.params[1]),"x","function parameters")
    eq(function_info.vararg,true,"function vararg")
    local body=Tree.Statements(function_info.body)
    local declaration=Tree.Match(body[1],"declaration")
    local fields=Tree.Match(declaration.values[1],"table").fields
    eq(Tree.Is(fields[1].value,"vararg"),true,"table element structure")
    local inner=Tree.Match(body[2],"return").values[1]
    eq(Tree.Is(inner,"function"),true,"nested function retained")
    local inside=Tree.Statements(Tree.Match(inner,"function").body)
    eq(Tree.Is(Tree.Match(inside[1],"return").values[1],"index"),true,"computed index retained")
    local method=Tree.Match(statements[3],"function_statement")
    eq(method.fn,Tree.Match(statements[3],"definition").fn,"statement pattern retains the canonical function node")
    eq(Tree.Match(statements[3],"assignment"),nil,"method statement is not an assignment")
    eq(Tree.Match(statements[2],"function_statement"),nil,"local function is not a global function statement")
    eq(Tree.Match(statements[4],"function_statement"),nil,"assignment is not a function statement")
    eq(method.method,true,"method declaration retained")
    eq(Tree.Path(method.target),"T:m","method path")
    local write=Tree.Match(statements[4],"assignment")
    eq(Tree.Identifier(Tree.Match(write.targets[1],"index").key),"k","assignment target index")
    local call=Tree.Match(write.values[1],"call")
    eq(Tree.Identifier(call.callee),"f","call callee")
    eq(Tree.Identifier(call.args[1]),"a","call arguments")
    eq(Tree.String(Tree.Match(statements[5],"call_statement").args[1]),"path","decoded sugar argument")
    eq(type(fn),"cdata","function is the original native entity")
    eq(fn,statements[2],"function and declaration views share one native entity")
    eq(Tree.Match(statements[2],"definition").fn,fn,"repeated capture identity")
    local foreign=analyze("local function f(x,...) end")
    eq(Tree.IsNode(foreign.syntax.root),false,"different source snapshots")
    eq(Tree.IsNode({kind="function"}),false,"raw node cannot impersonate a reference")
    eq(pcall(Tree.Match,{kind="function"},"function"),false,"foreign match is an error, not no-match")
    eq(pcall(Tree.Match,fn,"unknown-pattern"),false,"unknown contract operation refused")
    eq(Tree.Match(fn,"assignment"),nil,"valid structural nonmatch")
    first.names[1]=nil
    eq(#Tree.Match(statements[1],"declaration").names,2,"capture list is detached")
    local saw_inner,visited_inner=false,false
    Tree.Walk(fn,function(node,parent,depth)
        if node==inner then
            eq(depth,2,"function nesting depth")
            eq(parent,body[2],"stable parent identity")
            saw_inner=true;return false
        end
        if node==inside[1] then visited_inner=true end
    end)
    eq(saw_inner,true,"nested function observed")
    eq(visited_inner,false,"false prunes nested subtree")
    local simple=analyze("local f=function() end; local function g() end;")
    local Simple=simple.syntax
    local defs=Simple.Statements(Simple.root)
    eq(Simple.Match(defs[1],"definition").self_visible,false,"initializer has no implicit self visibility")
    eq(Simple.Match(defs[2],"definition").self_visible,true,"local function has self visibility")
    local first,last=Simple.Range(defs[2])
    eq(simple.source:sub(first,last),Simple.Text(defs[2]),"range follows native statement bytes")
    eq(table.concat(a.declaration_names,","),"a,b,f","declarations consume shared tree")
    -- Literal data with code-looking text cannot create a class or callback.
    local source="local decoy=\"_editor_class['Fake'].cards={}\"; _editor_class['K']=Class(boss); _editor_class['K'].cards={}; _tmp_sc=boss.card.New('C',1,2,3,4,{1,2,3}); function _tmp_sc:init(...) return function(...) return ... end end; table.insert(_editor_class['K'].cards,_tmp_sc)"
    local facts=assert(Source.Build(source))
    local analysis=facts.analysis
    local original_parse=Syntax.Parse
    Syntax.Parse=function() error("shared syntax reparsed") end
    local ok,why=pcall(function()
        local matched=assert(discover(facts))
        local classes=matched.classes
        eq(#classes,1,"only real class is discovered")
        eq(classes[1].class_key,"K","class key from index literal")
        eq(matched.source,facts,"Card consumes the exact complete shared Source")
        eq(analysis.tokens,nil,"shared discovery has no token array")
        local layout=matched.by_class.K.layout
        eq(#layout,1,"registration from call node")
        eq(layout[1].name,"C","constructor argument value")
        eq(layout[1].callback_syntax.init,analysis.syntax.Match(analysis.statements[5].syntax,"definition").fn,"callback reuses original function node")
        local body=layout[1].callbacks.init
        assert(loadstring("return "..body))
        eq(body:sub(1,17),"function(self,...","method vararg receiver inserted")
        local made=assert(Compose.Create(body,nil,{}, {form="expression",tree=analysis.syntax,syntax=layout[1].callback_syntax.init}))
        eq(type(made.fn),"function","composition reuses function syntax")
        eq(Source.Declarations(facts),analysis.declarations,"scope queries reuse shared declarations")
    end)
    Syntax.Parse=original_parse;assert(ok,why)
    eq(#assert(discover(assert(Source.Build("_editor_class['K'].cards,other={},0")))).classes,0,"multi-target write is not a list anchor")
    eq(#assert(discover(assert(Source.Build("_editor_class['K'].cards=factory()")))).classes,0,"unknown RHS is not a table")
    -- Decoder agrees with runtime literal semantics; no analyzed chunk is executed.
    for _,raw in ipairs({"'a\\n\\097'","'\\\\\\\"\\''","[=[\r\nline\rnext]=]","'a\\\r\nb'","'\\000\\255'"}) do
        local literal=analyze("local v="..raw).syntax
        local value=literal.Match(literal.Statements(literal.root)[1],"declaration").values[1]
        eq(literal.String(value),assert(loadstring("return "..raw))(),"literal decoder "..raw)
    end
    local Scanner=require("SpellHotReload.Adapters.Card.GeneratedBossScanner")
    local bom=assert(Source.Build("\239\187\191"..source))
    local old_build,old_analyze=Source.Build,IR.Analyze
    local old_parse=Syntax.Parse
    local previous=rawget(_G,"_")
    local marker=function() end
    _G._=marker
    local function forbidden() error("class-key hint rebuilt shared analysis") end
    Source.Build,IR.Analyze=forbidden,forbidden
    Syntax.Parse=forbidden
    local queried,query_error=pcall(function()
        local keys=assert(Scanner.ClassKeys(facts))
        eq(keys.K,true,"class-key hint consumes shared tree")
        eq(keys.Fake,nil,"class-key hint ignores code-looking string")
        eq(assert(Scanner.ClassKeys(bom)).K,true,"BOM source retains shared AST provenance")
        eq(Scanner.ClassKeys(source),nil,"raw bytes cannot trigger hidden analysis")
        eq(Scanner.ClassKeys(analysis),nil,"unbound syntax snapshot is not FileAnalysis")
        local changed={};for key,value in pairs(facts) do changed[key]=value end
        changed.content=source.." "
        local none,reason=Scanner.ClassKeys(changed)
        eq(none,nil,"different bytes cannot reuse old facts")
        eq(reason.code,"stale","different bytes diagnostic")
        changed={};for key,value in pairs(facts) do changed[key]=value end
        changed.analysis={};for k,v in pairs(facts.analysis) do changed.analysis[k]=v end
        changed.analysis.declarations={}
        eq(Scanner.ClassKeys(changed),nil,"replaced declaration index refused")
        local again=assert(Scanner.ClassKeys(facts))
        keys.K=nil;keys.Invented=true
        eq(again.K,true,"hint result is detached")
        eq(again.Invented,nil,"hint mutation never changes shared syntax")
    end)
    Source.Build,IR.Analyze=old_build,old_analyze
    Syntax.Parse=old_parse
    local preserved=rawget(_G,"_")==marker
    _G._=previous
    assert(queried,query_error)
    eq(preserved,true,"class-key hint preserves translation global")
    for _,raw in ipairs({"'\\x41'","'\\z space'","'\\u{41}'","'\\q'"}) do
        local nodes,reason=IR.Analyze("local v="..raw)
        eq(nodes,nil,"unsupported escape refused "..raw)
        eq(type(reason),"string","escape refusal diagnostic "..raw)
    end
    for _,tail in ipairs({"_tmp_sc.init=function() end,side_effect()","_tmp_sc.init,other=function() end,0"}) do
        local bad=source:gsub("function _tmp_sc:init%(%.%.%.%) return function%(%.%.%.%) return %.%.%. end end",tail)
        local layout,why=discover(assert(Source.Build(bad)))
        eq(layout,nil,"compound callback assignment refused")
        eq(why.phase,"match","compound callback rejected at shared matching")
        eq(why.code,"unsupported","compound callback diagnostic")
    end
    -- Tree reference traversal excludes declaration names and field/record labels.
    local names_tree=analyze("local obj={field=value,[key]=other}; obj:field(value)").syntax
    local refs=names_tree.Names(names_tree.root)
    local names={};for _,ref in ipairs(refs) do names[#names+1]=names_tree.Identifier(ref) end
    eq(table.concat(names,","),"value,key,other,obj,value","reference structure")
    -- Byte spans use original file coordinates; no owner performs token/BOM math.
    for _,callback_text in ipairs({
        "function _tmp_sc:init(...) return [=[甲\r\n乙]=],... end;",
        "_tmp_sc.init=function(...) return [=[甲\r\n乙]=],... end;",
    }) do
        local bytes="\239\187\191-- 中文 byte offsets\r\n"
            .."_editor_class['K']=Class(boss);\r\n_editor_class['K'].cards={};\r\n"
            .."_tmp_sc=boss.card.New('C',1,2,3,4,{1,2,3});\r\n"..callback_text
            .."\r\ntable.insert(_editor_class['K'].cards,_tmp_sc);"
        local complete=assert(Source.Build(bytes))
        local Tree=complete.analysis.syntax
        local callback_statement=Tree.Statements(Tree.root)[4]
        local function_node=Tree.Match(callback_statement,"definition").fn
        local foreign=assert(Source.Build(bytes))
        local expected_first,expected_last=assert(bytes:find(callback_text,1,true))
        local old_parse=Syntax.Parse
        Syntax.Parse=function() error("byte range reparsed syntax") end
        local queried,problem=pcall(function()
            local whole=assert(Source.ByteRange(complete,callback_statement))
            local body_range=assert(Source.ByteRange(complete,function_node,"function"))
            eq(whole.first,expected_first,"statement original byte start with BOM/UTF-8/CRLF")
            eq(bytes:sub(whole.first,whole.last),Tree.Text(callback_statement),"statement range equals native span")
            eq(body_range.first,bytes:find("function",expected_first,true),"function starts at its own keyword")
            eq(body_range.last,expected_last-1,"function span excludes statement semicolon")
            local layout=assert(discover(complete)).by_class.K.layout
            eq(layout[1].callback_points.init.first,expected_first,"callback includes assignment/declaration prefix")
            eq(layout[1].callback_points.init.last,expected_last-1,"callback ends at function end")
            whole.first=0
            eq(assert(Source.ByteRange(complete,callback_statement)).first,expected_first,"range record is detached")
            local invalid,reason=Source.ByteRange(complete,{kind="function"})
            eq(invalid,nil,"fabricated range node refused");eq(reason.code,"stale","fabricated range diagnostic")
            complete.sites[foreign.analysis.syntax.root]={statement=false}
            invalid,reason=Source.ByteRange(complete,foreign.analysis.syntax.root)
            complete.sites[foreign.analysis.syntax.root]=nil
            eq(invalid,nil,"foreign snapshot refused even with an invented site")
            eq(reason.code,"stale","foreign range diagnostic")
            local changed={};for key,value in pairs(complete) do changed[key]=value end
            changed.content=bytes.." "
            invalid,reason=Source.ByteRange(changed,function_node)
            eq(invalid,nil,"changed original bytes refused");eq(reason.code,"stale","changed bytes diagnostic")
        end)
        Syntax.Parse=old_parse
        assert(queried,problem)
    end
    local empty=assert(Source.Build(""))
    local no_range,range_error=Source.ByteRange(empty,empty.analysis.syntax.root)
    eq(no_range,nil,"empty node has no fabricated byte range")
    eq(range_error.code,"unsupported","empty range is explicit")
    -- Traversal order, empty bodies, reentrancy and eager immediate-child refusal.
    do
        local tree=assert(Syntax.Parse("while flag do end; repeat until done; return f(arg)"))
        local order={};local reentered=false
        tree.Walk(tree.root,function(n,parent,functions,calls)
            if tree.Is(n,"name") then
                local name=tree.Identifier(n)
                order[#order+1]=name..":"..functions..":"..calls
                if name=="f" then
                    tree.Walk(n,function(s,p,fd,cd)
                        eq(s,n,"reentrant walk keeps node identity")
                        eq(p,nil,"reentrant walk has its own root parent")
                        eq(fd,0,"reentrant function depth starts at zero")
                        eq(cd,0,"reentrant call depth starts at zero")
                    end)
                    reentered=true
                end
            end
        end)
        eq(table.concat(order,","),"flag:0:0,done:0:0,f:0:1,arg:0:1","empty control bodies and call order")
        eq(reentered,true,"visitor can start an independent walk")
        local guarded=assert(Syntax.Parse([[return a,'\x41']]))
        local visits=0
        guarded.Walk(guarded.root,function(n)
            visits=visits+1
            if guarded.Is(n,"return") then return false end
        end)
        eq(visits,2,"pruned children are not materialized")
        local names={}
        local ok=pcall(guarded.Walk,guarded.root,function(n)
            if guarded.Is(n,"name") then names[#names+1]=guarded.Identifier(n) end
        end)
        eq(ok,false,"value walk still rejects unsupported escape")
        eq(#names,0,"all immediate children resolve before first child callback")
        local refs=guarded.Names(guarded.root)
        eq(#refs,1,"failed value walk preserves opaque reference traversal")
        eq(guarded.Identifier(refs[1]),"a","reference traversal skips literal decoding")
    end
    print("SyntaxTreeSpec: "..passed.." passed / 0 failed")
    return {passed=passed,failed=0}
end
return M
