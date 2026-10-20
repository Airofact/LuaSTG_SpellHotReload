-- Grammar boundaries and failure propagation; candidates are never executed.
local M={}
function M.run()
    local IR=require("SpellHotReload.Source.TopLevelIR")
    local Binding=require("SpellHotReload.Source.Binding")
    local Lexer=require("SpellHotReload.Source.Lexer")
    local passed,failed,failures=0,0,{}
    local function check(v,label) if v then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end end
    local function eq(a,b,label) check(a==b,label..": "..tostring(a).." ~= "..tostring(b)) end
    local compile=loadstring
    local cases={
        {{"a=1","b=2","c=3"}},
        {{"a,b=1,2","c=3"}},
        {{"local x","local y=2","x=y"}},
        {{"local a=1 +\n2 *\n3","b=a"}},
        {{"x=foo.bar[1]:method{a=2,[3]=4;5,}","next()"}},
        {{"local f=function(a,...) return a,... end","f'hello'","f [[world]]"}},
        {{"function A.B:C(x) self.x=x end","T[1]=function() return 2 end"}},
        {{"if x then a() elseif y then b() else c() end","finish()"}},
        {{"for i=1,10,2 do while a do break end end","for k,v in pairs(t) do do f(v) end end"}},
        {{"repeat local x=1 until x>0 and foo()","next()"}},
        {{"do local function f() return function(...) return ... end end end","next()"}},
        {{"t={a=function(x,y) return x,y end;[foo(1,2)]=3,4}","x=-2^2 .. 'x'"}},
        {{"a=(factory())[key](1)","object=(factory()).x"}},
        {{"x=0x1f + .25e-2 - 12.E+3 + 0x1e+2","y=1 ~= 2 and not false or nil"}},
        {{"local x='-- if end'","local y=[=[\nfunction x() end --\n]=]","ready()"}},
        {{"local x=1 --[[ comment end ]=] ]]","-- comment\nfinish()"}},
    }
    for n,case in ipairs(cases) do
        local statements=case[1]
        for k,sep in ipairs({" ","\n","; ",";\r\n"}) do
            local source=table.concat(statements,sep)
            local compiled,why=compile(source)
            check(compiled~=nil,"fixture syntax "..n.."/"..k..": "..tostring(why))
            local rows,err=IR.SplitStatements(source)
            check(rows~=nil,"parse "..n.."/"..k..": "..tostring(err))
            if rows then
                eq(#rows,#statements,"statement count "..n.."/"..k)
                local nodes,reason,analysis=IR.Analyze(source)
                check(nodes~=nil,"analyze "..n.."/"..k..": "..tostring(reason))
                if analysis then
                    local next_token=1
                    for _,row in ipairs(analysis.statements) do
                        eq(row.tok.first,next_token,"contiguous token partition")
                        next_token=row.tok.last+1
                        eq(source:sub(row.source_range.first,row.source_range.last),row.text,"exact original bytes")
                    end
                    eq(next_token,#analysis.tokens+1,"full token partition")
                end
            end
        end
    end
    local invalid={"a=","x=1e+","x=0x","x=1..2","x=12abc","f(","x={a=1", "if x then f()",
        "local = 1","function f(x,) end","function f(...) return function() return ... end end",
        "break","while true do function f() break end end","return 1 a=2","local x='unterminated",
        "--[=[ unfinished","local x=[=[unfinished","local x='a\nb'","local x='\\256'",
        "f()=1","(a)=1","f(a) g","a = f\n(1)","local x=1 + end","if x then else elseif y then end", ";a=1", "a=1;;b=2", "local x=... ...", "x={;}", "x={a=}", "for i=1,2 f() end", "f:x", "function f(...,a) end"}
    for n,source in ipairs(invalid) do
        check(compile(source)==nil,"invalid fixture "..n)
        local rows,why=IR.SplitStatements(source)
        eq(rows,nil,"bad split fails closed "..n)
        check(type(why)=="string","bad split diagnostic "..n)
        local nodes,reason,analysis=IR.Analyze(source)
        eq(nodes,nil,"invalid source has no nodes "..n)
        eq(analysis,nil,"invalid source has no analysis "..n)
        check(type(reason)=="string","analyze diagnostic "..n)
    end
    local _,_,analysis=IR.Analyze("local a=1 local b=a local c=b")
    local bindings=assert(Binding.Analyze(analysis))
    check(bindings.statements[2].visible.a~=nil,"same-line definition-point visibility")
    eq(bindings.statements[1].visible.a,nil,"initializer not self-visible")
    check(bindings.statements[3].visible.b~=nil,"third statement visibility")
    local _,_,bom=IR.Analyze("\239\187\191a=1\r\nb=2\rc=3\nd=4")
    eq(bom.statements[1].source_range.first,4,"BOM original offset")
    for i=1,4 do eq(bom.statements[i].line,i,"all newline forms") end
    eq(#assert(IR.SplitStatements("a=(factory())[key](1); (factory()).x=1")),2,"parenthesized next statement requires separator")
    local old_compile,old_load,old_loadfile=loadstring,load,loadfile
    local calls=0
    local function trap() calls=calls+1;error("analyzer compiled candidate") end
    loadstring,load,loadfile=trap,trap,trap
    local ok,reason=pcall(function()
        assert(IR.Analyze("UNRUN() x=1 y=2"))
        assert(IR.Analyze("function UNRUN() error('never') end"))
    end)
    loadstring,load,loadfile=old_compile,old_load,old_loadfile
    check(ok,"pure parser: "..tostring(reason));eq(calls,0,"zero compiler calls")
    local tokens,err=Lexer.Tokenize("--[=[ broken")
    check(type(tokens)=="table" and type(err)=="string","lexer reports truncated long comment")
    -- Differential examples for lexical and expression continuation edges.
    -- Compilation is an oracle in this test only; the resulting chunks are
    -- discarded. Nothing in this corpus is called or registered.
    local expressions={
        "nil", "false", "true", "0", "0x1e+2", "0XFF-1", ".5e+2", "12.E-2",
        "'a\\123b'", "[==[brackets ]=] and -- are opaque]==]",
        "{a=1; [x+y]=2, function() return 3 end,}",
        "function(x,...) if x then return ... end return x end",
        "factory()[index].field", "object:method(1,2):next{a=3}",
        "(factory())(1)", "f 'text' [[more]]", "#items", "not object",
        "-2^2", "2^-2", "a..b..c", "a<b and b~=c or d>=e",
        "a + b * c ^ d / e % f", "{[f(1,2)]=g{x=2}; [3]={4,5}}",
    }
    for n,expression in ipairs(expressions) do
        for _,separator in ipairs({" ","\n","; ",";\r\n"}) do
            local source="local first="..expression..separator.."local second=first"..separator.."UNRUN(second)"
            local compiled,why=compile(source)
            check(compiled~=nil,"expression oracle "..n..": "..tostring(why))
            local rows,reason=IR.SplitStatements(source)
            check(rows~=nil,"expression continuation "..n..": "..tostring(reason))
            if rows then eq(#rows,3,"expression consumes only its statement") end
        end
    end
    local control={
        "while true do if x then break else f() end end",
        "repeat do local v=1 end until f{a=2}",
        "for i,j,k in f(),g(1,2),{3,4} do if i then return j end end",
        "function outer(a,...) local function inner(...) return ... end return inner(...) end",
        "do local a,b,c local function f(x) repeat x=x-1 until x<=0 return x end end",
    }
    for n,source in ipairs(control) do
        source=source.."; UNRUN()"
        check(compile(source)~=nil,"control oracle "..n)
        local rows,reason=IR.SplitStatements(source)
        check(rows~=nil,"complete control block "..n..": "..tostring(reason))
        if rows then eq(#rows,2,"block owns nested statements") end
    end
    local strings={
        "local s='escaped\\\'quote' next()",
        "local s=\"escaped\\\"quote\" next()",
        "local s='escaped\\\nnewline' next()",
        "local s='escaped\\\r\nnewline' next()",
        "local s='\\0000\\255' next()",
    }
    for n,source in ipairs(strings) do
        check(compile(source)~=nil,"literal oracle "..n)
        local rows,reason=IR.SplitStatements(source)
        check(rows~=nil,"literal remains opaque "..n..": "..tostring(reason))
        if rows then eq(#rows,2,"literal does not consume next statement") end
    end
    local blocks="value="..string.rep("(",180).."1"..string.rep(")",180)
    local too_deep,depth_reason=IR.Analyze(blocks)
    eq(too_deep,nil,"deep input fails closed")
    check(type(depth_reason)=="string" and depth_reason:find("limit",1,true),"nesting diagnostic")
    for _,source in ipairs({"local x=1LL","::label:: goto label","local x=0x1.fp2"}) do
        local unsupported,reason=IR.Analyze(source)
        eq(unsupported,nil,"unsupported dialect has no partial nodes")
        check(type(reason)=="string","unsupported dialect diagnostic")
    end
    for _,source in ipairs({"", "-- only comment", "--[=[closed]=]"}) do
        eq(#assert(IR.SplitStatements(source)),0,"empty source partition")
    end
    local invalid,why=IR.Analyze(false)
    eq(invalid,nil,"non-source input rejected");eq(type(why),"string","input diagnostic")
    for _,newline in ipairs({"\r","\n","\r\n","\n\r"}) do
        local rows=assert(IR.SplitStatements("-- comment"..newline.."NEXT()"))
        eq(#rows,1,"line comment ends on every Lua newline form")
        eq(rows[1].line,2,"line comment does not consume next statement")
    end
    local multiline="local s=[=[a\r\nb\r\nc]=]\r\nNEXT()"
    local _,_,locations=IR.Analyze(multiline)
    eq(locations.statements[2].line,4,"line count after multiline opaque token")
    local FileMatch=require("SpellHotReload.Pipeline.FileMatch")
    local registry={Discoveries=function() return {} end}
    local found,refusal=FileMatch.Discover(registry,"local x=",{file="broken.lua"})
    eq(found,nil,"discovery cannot produce zero-match deletion from broken syntax")
    check(refusal and refusal.phase=="analyze","invalid discovery reason phase")
    print(string.format("LuaSyntaxSpec: %d passed / %d failed",passed,failed))
    for _,why in ipairs(failures) do print("  FAIL "..why) end
    return {passed=passed,failed=failed}
end
return M
