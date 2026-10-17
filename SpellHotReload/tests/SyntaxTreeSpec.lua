-- Shared structural evidence and downstream reuse, with no runtime ownership claims.
local M={}
function M.run()
    local IR=require("SpellHotReload.Source.TopLevelIR")
    local Tree=require("SpellHotReload.Source.SyntaxTree")
    local Syntax=require("SpellHotReload.Source.LuaSyntax")
    local Lexer=require("SpellHotReload.Source.Lexer")
    local Binding=require("SpellHotReload.Source.Binding")
    local Cards=require("SpellHotReload.Adapters.Card.Card")
    local Callbacks=require("SpellHotReload.Adapters.Card.CardCallbacks")
    local Compose=require("SpellHotReload.Source.Compose")
    local passed=0
    local function eq(a,b,label) assert(a==b,label..": "..tostring(a).." ~= "..tostring(b));passed=passed+1 end
    local function analyze(source)
        local nodes,err,analysis=IR.Analyze(source);assert(nodes,err);return analysis
    end
    local a=analyze("local a,b=1,2; local function f(x,...) local b={...};return function(y) return b[y],a end end; function T:m(n) return self,n end; T[k]=f(a); Include'path'")
    eq(a.syntax.kind,"chunk","root kind")
    eq(a.statements[1].syntax,a.syntax.body[1],"shared statement identity")
    eq(#a.syntax.body,5,"statement count")
    local first=a.syntax.body[1]
    eq(first.kind,"local","local node")
    eq(#first.names,2,"binding list")
    eq(first.names[1].kind,"binding","declaration distinct from name read")
    eq(first.values[2].literal_kind,"number","numeric literal category")
    local fn=a.syntax.body[2].fn
    eq(fn.params[1].name,"x","function parameters")
    eq(fn.vararg,true,"function vararg")
    eq(fn.body.body[1].values[1].fields[1].value.kind,"vararg","table element structure")
    local inner=fn.body.body[2].values[1]
    eq(inner.kind,"function","nested function retained")
    eq(inner.body.body[1].values[1].kind,"index","computed index retained")
    eq(a.syntax.body[3].method,true,"method declaration retained")
    eq(Tree.Path(a.syntax.body[3].target),"T:m","method path")
    local write=a.syntax.body[4]
    eq(write.targets[1].key.name,"k","assignment target index")
    eq(write.values[1].callee.name,"f","call callee")
    eq(write.values[1].args[1].name,"a","call arguments")
    eq(a.syntax.body[5].expression.args[1].value,"path","decoded sugar argument")
    local bindings=assert(Binding.Analyze(a))
    eq(table.concat(bindings.names,","),"a,b,f","declarations consume shared tree")
    -- Literal data with code-looking text cannot create a class or callback.
    local source="local decoy=\"_editor_class['Fake'].cards={}\"; _editor_class['K']=Class(boss); _editor_class['K'].cards={}; _tmp_sc=boss.card.New('C',1,2,3,4,{1,2,3}); function _tmp_sc:init(...) return function(...) return ... end end; table.insert(_editor_class['K'].cards,_tmp_sc)"
    local analysis=analyze(source)
    local original_parse,original_lex=Syntax.Parse,Lexer.Tokenize
    Syntax.Parse=function() error("shared syntax reparsed") end
    Lexer.Tokenize=function() error("shared syntax re-lexed") end
    local ok,why=pcall(function()
        local classes=assert(Cards.CardLists(analysis))
        eq(#classes,1,"only real class is discovered")
        eq(classes[1].class_key,"K","class key from index literal")
        local layout=assert(Callbacks.Read(source,"K",analysis))
        eq(#layout,1,"registration from call node")
        eq(layout[1].name,"C","constructor argument value")
        eq(layout[1].callback_syntax.init,analysis.syntax.body[5].fn,"callback reuses original function node")
        local body=layout[1].callbacks.init
        assert(loadstring("return "..body))
        eq(body:sub(1,17),"function(self,...","method vararg receiver inserted")
        local made=assert(Compose.Create(body,nil,{}, {form="expression",syntax=layout[1].callback_syntax.init}))
        eq(type(made.fn),"function","composition reuses function syntax")
        assert(Binding.Analyze(analysis))
    end)
    Syntax.Parse=original_parse;Lexer.Tokenize=original_lex;assert(ok,why)
    eq(#assert(Cards.CardLists(analyze("_editor_class['K'].cards,other={},0"))),0,"multi-target write is not a list anchor")
    eq(#assert(Cards.CardLists(analyze("_editor_class['K'].cards=factory()"))),0,"unknown RHS is not a table")
    -- Decoder agrees with runtime literal semantics; no analyzed chunk is executed.
    for _,raw in ipairs({"'a\\n\\097'","'\\\\\\\"\\''","[=[\r\nline\rnext]=]","'a\\\r\nb'","'\\000\\255'"}) do
        local tokens=assert(Lexer.Tokenize(raw))
        eq(tokens[1].literal,assert(loadstring("return "..raw))(),"literal decoder "..raw)
    end
    local Scanner=require("SpellHotReload.Adapters.Card.GeneratedBossScanner")
    local keys=Scanner.ClassKeys(source,analysis)
    eq(keys.K,true,"class-key hint consumes shared tree")
    eq(keys.Fake,nil,"class-key hint ignores code-looking string")
    local previous=rawget(_G,"_")
    local marker=function() end
    _G._=marker
    local standalone=Scanner.ClassKeys(source)
    local preserved=rawget(_G,"_")==marker
    _G._=previous
    eq(standalone.K,true,"standalone class-key hint parses its own source")
    eq(preserved,true,"standalone query preserves translation global")
    for _,raw in ipairs({"'\\x41'","'\\z space'","'\\u{41}'","'\\q'"}) do
        local _,reason=Lexer.Tokenize(raw)
        eq(type(reason),"string","unsupported escape refused "..raw)
    end
    for _,tail in ipairs({"_tmp_sc.init=function() end,side_effect()","_tmp_sc.init,other=function() end,0"}) do
        local bad=source:gsub("function _tmp_sc:init%(%.%.%.%) return function%(%.%.%.%) return %.%.%. end end",tail)
        local layout,why=Callbacks.Read(bad,"K")
        eq(layout,nil,"compound callback assignment refused")
        eq(type(why),"string","compound callback diagnostic")
    end
    -- Tree reference traversal excludes declaration names and field/record labels.
    local refs=Tree.Names(analyze("local obj={field=value,[key]=other}; obj:field(value)").syntax)
    local names={};for _,ref in ipairs(refs) do names[#names+1]=ref.name end
    eq(table.concat(names,","),"value,key,other,obj,value","reference structure")
    print("SyntaxTreeSpec: "..passed.." passed / 0 failed")
    return {passed=passed,failed=0}
end
return M
