-- Canonical declarations and definition-point scope, not complete Lua binding.
local Source=require("SpellHotReload.Source.FileAnalysis")
local IR=require("SpellHotReload.Source.TopLevelIR")
local M={}
function M.run()
    local passed=0
    local function eq(a,b,label) assert(a==b,label);passed=passed+1 end
    local function must(v,e) assert(v,type(e)=="table" and e.message or e);return v end
    local function build(text,previous)
        local source=must(Source.Build(text,nil,previous))
        return source,source.analysis
    end
    local function declaration(s,name) return Source.Declaration(s,name) end
    local function resolve(s,index,name) return Source.ResolveLocal(s,index,name) end
    local function names(s) return table.concat(Source.DeclaredNames(s),",") end
    local function fn(s,index) return s.analysis.syntax.Match(s.analysis.statements[index].syntax,"definition").fn end
    local source,a=build("local a = 1\nlocal function f() end\nlocal b, c\nG = 1")
    local declarations=Source.Declarations(source)
    eq(#declarations,4,"every top-level local is a declaration")
    eq(names(source),"a,f,b,c","first-declaration order")
    eq(declaration(source,"a").kind,"value","value kind")
    eq(declaration(source,"f").kind,"function","function kind")
    eq(declaration(source,"b").kind,"declare","declare kind")
    eq(declaration(source,"b").slot,1,"first declaration slot")
    eq(declaration(source,"c").slot,2,"second declaration slot")
    eq(declaration(source,"f").self_visible,true,"local function self visibility")
    eq(declaration(source,"a").self_visible,false,"ordinary local has no self prefix")
    eq(declaration(source,"a").statement,1,"first statement index")
    eq(declaration(source,"c").statement,3,"multi-name statement index")
    for i,d in ipairs(declarations) do
        eq(d,a.nodes[i],"one canonical declaration entity in IR")
        eq(d,declaration(source,d.name),"unique lookup shares entity")
        eq(d,a.declarations_by_name[d.name][1],"name index shares entity")
        eq(d.ordinal,i,"source-order ordinal")
        eq(d.syntax,a.statements[d.statement].syntax,"declaration uses original statement")
        eq(d.source_range,a.statements[d.statement].source_range,"range shares statement identity")
        eq(a.syntax.Identifier(d.name_syntax),d.name,"name syntax retained")
        eq(Source.ContainsFact(source,d),true,"canonical declaration belongs to source")
        eq(Source.ContainsFact(source,d.name_syntax),true,"name syntax belongs to source")
    end
    eq(#Source.Duplicates(source),0,"no duplicate declarations")
    eq(a.binding_complete,nil,"no obsolete binding-model field")
    eq(a.scope_complete,true,"top-level declaration sequence is complete")
    eq(source.bindings,nil,"no second binding model")
    eq(a.statements[1].scope_before,0,"first statement frontier")
    eq(a.statements[3].scope_before,2,"frontier excludes all current declarations")
    eq(a.statements[4].scope_before,4,"multi-name declaration advances frontier")
    eq(resolve(source,1,"a"),nil,"initializer cannot see itself")
    eq(resolve(source,2,"a"),declarations[1],"previous declaration visible")
    eq(resolve(source,3,"f"),declarations[2],"function visible later")
    eq(resolve(source,4,"c"),declarations[4],"last multi-name declaration visible")
    local first_name=must(Source.ByteRange(source,declarations[1].name_syntax))
    eq(source.content:sub(first_name.first,first_name.last),"a","original declaration-name bytes")

    source,a=build("local x=1\nlocal x=x+1\nG=x")
    declarations=Source.Declarations(source)
    local duplicates=Source.Duplicates(source)
    eq(#duplicates,1,"duplicate name detected")
    eq(duplicates[1].name,"x","duplicate name")
    eq(duplicates[1].count,2,"duplicate count")
    eq(duplicates[1].declarations[2],declarations[2],"duplicate index uses canonical entities")
    eq(declaration(source,"x"),nil,"duplicate name has no unique declaration")
    eq(names(source),"x","ordered unique names")
    eq(resolve(source,2,"x"),declarations[1],"local x=x reads previous x")
    eq(resolve(source,3,"x"),declarations[2],"later use sees newest x")
    source=build("local x=1; local x,x=x,x; G=x")
    declarations=Source.Declarations(source)
    eq(resolve(source,2,"x"),declarations[1],"same-statement initializers use earlier x")
    eq(resolve(source,3,"x"),declarations[3],"last same-statement declaration shadows")
    source=build("local a=1; local b=2; local b=3; local a=4")
    duplicates=Source.Duplicates(source)
    eq(duplicates[1].name,"a","duplicates keep first-declaration order")
    eq(duplicates[2].name,"b","duplicate encounter order does not reorder names")

    source=build("local f=function() return f end\nlocal function g(n) return n>0 and g(n-1) end")
    eq(table.concat(Source.Visible(source,fn(source,1)),","),"","ordinary initializer does not see its own f")
    eq(table.concat(Source.Visible(source,fn(source,2)),","),"f,g","local function sees f and itself")
    eq(resolve(source,2,"g"),nil,"self name not visible before statement")
    eq(source.analysis.statements[2].self_declaration,declaration(source,"g"),"self context points to canonical entity")
    source=build("G=b\nlocal b=2")
    eq(resolve(source,1,"b"),nil,"forward read is global")
    eq(resolve(source,2,"b"),nil,"declaration not visible in initializer")

    source,a=build("local x=1\nlocal function g() local x=2; return x end\nG=x")
    eq(#Source.Declarations(source),2,"nested local is not a top-level declaration")
    eq(resolve(source,2,"x"),declaration(source,"x"),"outer x visible at function definition")
    eq(resolve(source,3,"x"),declaration(source,"x"),"body-local shadow does not escape")
    source=build("local a=1\n-- local b=2\nG='a'\nS=[[local c=3]]")
    eq(names(source),"a","comments and strings never declare")
    eq(resolve(source,3,"a"),declaration(source,"a"),"literal statement preserves outer scope")
    for _,text in ipairs({"local i=1; for i=1,10 do local hidden=i end; G=i",
        "local i={}; for k,v in pairs(i) do local hidden=v end; G=i",
        "local i=1; repeat local hidden=i until i>hidden; G=i"}) do
        source=build(text)
        eq(names(source),"i","block locals stay private")
        eq(resolve(source,2,"i"),declaration(source,"i"),"outer visible at block entry")
        eq(resolve(source,3,"i"),declaration(source,"i"),"outer survives block")
        eq(declaration(source,"hidden"),nil,"nested declaration not exported")
    end
    source=build("function T.m() return T end")
    eq(#Source.Declarations(source),0,"field function does not declare a local")

    source=build("local outer=1; local function recur(n) local inner=function() return outer end; return recur(n-1) end; local later=recur")
    local Tree=source.analysis.syntax
    local walk,refs,match,analyze=Tree.Walk,Tree.Names,Tree.Match,IR.Analyze
    local function forbidden() error("scope query rebuilt or walked syntax",0) end
    Tree.Walk,Tree.Names,Tree.Match,IR.Analyze=forbidden,forbidden,forbidden,forbidden
    local ok,reason=pcall(function()
        eq(names(source),"outer,recur,later","query uses existing ordered declarations")
        eq(resolve(source,2,"outer"),declaration(source,"outer"),"query preserves declaration identity")
        eq(table.concat(Source.VisibleBefore(source,3),","),"outer,recur","frontier queried without syntax scan")
        local visible=Source.VisibleBefore(source,3);visible[1]="changed"
        eq(table.concat(Source.VisibleBefore(source,3),","),"outer,recur","returned names have independent storage")
    end)
    Tree.Walk,Tree.Names,Tree.Match,IR.Analyze=walk,refs,match,analyze
    must(ok,reason)
    local inner=Tree.Match(Tree.Statements(Tree.Match(fn(source,2),"function").body)[1],"definition").fn
    eq(Source.Visible(source,inner),nil,"nested function cannot use top-level-only preparation context")
    local other=build(source.content)
    eq(Source.Visible(other,fn(source,2)),nil,"same text in another snapshot is not original context")
    eq(Source.Owns(other,inner),false,"foreign nested handle refused")
    eq(Source.ContainsFact(source,_G),false,"runtime environment is not a source fact")
    eq(Source.ContainsFact(source,{}),false,"unrelated metadata is not a source fact")
    local statement=source.analysis.statements[2]
    source.analysis.statements[2]=other.analysis.statements[2]
    eq(Source.Statement(source,2),nil,"foreign same-position statement refused")
    source.analysis.statements[2]=statement
    local frontier=statement.scope_before;statement.scope_before=0
    eq(Source.Statement(source,2),nil,"frontier cannot omit preceding declaration")
    statement.scope_before=frontier
    eq(Source.Statement(source,2),statement,"restored canonical statement")

    -- Same function text, changed preceding scope: native reuse is not binding reuse.
    local body="local function use() return x end"
    local old=build(body.."\nlocal x=1")
    local old_decl=declaration(old,"x")
    local moved=build("local x=1\n"..body,old)
    local renamed=build("local y=1\n"..body,moved)
    eq(old.analysis.syntax.FunctionSource(fn(old,1),false),moved.analysis.syntax.FunctionSource(fn(moved,2),false),"function bytes unchanged across outer edit")
    eq(table.concat(Source.Visible(old,fn(old,1)),","),"use","old definition has no local x")
    eq(table.concat(Source.Visible(moved,fn(moved,2)),","),"use,x","moved declaration changes context")
    eq(table.concat(Source.Visible(renamed,fn(renamed,2)),","),"use,y","renamed outer declaration changes context again")
    eq(declaration(old,"x"),old_decl,"old declaration identity stays valid")
    eq(Source.Validate(old),true,"old source remains queryable")
    eq(Source.ContainsFact(moved,old_decl),false,"old declaration is not a candidate fact")
    eq(declaration(moved,"x")~=old_decl,true,"new snapshot has its own canonical declaration")

    source=build("");eq(#source.analysis.statements,0,"empty source has no statements")
    eq(#Source.Declarations(source),0,"empty source has no declarations")
    source=build("-- no code");eq(#Source.Declarations(source),0,"comment-only source")
    source=build("\239\187\191local a = 1\r\nG=a")
    local d=declaration(source,"a")
    eq(d.source_range.first,4,"BOM-aware statement start")
    eq(d.source_range.last,14,"BOM-aware statement end")
    eq(Source.ByteRange(source,d.name_syntax).first,10,"BOM-aware name range")
    eq(source.analysis.statements[2].line,2,"CRLF preserves line")
    local effect=rawget(_G,"SCOPE_FACTS_EFFECT");local touched=false
    _G.SCOPE_FACTS_EFFECT=function() touched=true end
    local built,problem=Source.Build("SCOPE_FACTS_EFFECT()")
    _G.SCOPE_FACTS_EFFECT=effect;must(built,problem)
    eq(touched,false,"analysis never executes candidate")
    for _,bad in ipairs({"local ???=1", "local", false, setmetatable({},{})}) do
        eq(Source.Build(bad),nil,"invalid input has no partial source facts")
    end
    eq(Source.Build(nil),nil,"nil source refused")
    eq(Source.Validate({}),nil,"fabricated source refused")
    eq(Source.Statement(source,0),nil,"invalid statement index refused")
    eq(Source.Statement(source,"1"),nil,"string statement index refused")
    local copied={};for k,v in pairs(source) do copied[k]=v end
    eq(Source.Validate(copied),nil,"copied public fields cannot forge provenance")
    local declarations=source.analysis.declarations
    source.analysis.declarations={}
    eq(Source.Validate(source),nil,"replaced canonical declaration index refused")
    source.analysis.declarations=declarations
    eq(Source.Validate(source),true,"restored facts remain valid")
    local last=table.remove(source.analysis.statements)
    eq(Source.Validate(source),nil,"truncated statement sequence refused")
    source.analysis.statements[#source.analysis.statements+1]=last
    setmetatable(source.analysis.declarations,{})
    eq(Source.Validate(source),nil,"metatable on canonical declaration index refused")
    setmetatable(source.analysis.declarations,nil)
    eq(Source.Validate(source),true,"complete plain indexes restored")

    -- Resource regression only; performance runs retain ordinary GC settings.
    local weak=setmetatable({},{__mode="v"})
    local function temporary()
        local s=build("local held=1")
        weak[1],weak[2],weak[3]=s,s.analysis,declaration(s,"held")
    end
    temporary()
    for _=1,3 do collectgarbage("collect") end
    eq(weak[1],nil,"provenance registry does not retain Source")
    eq(weak[2],nil,"released Source does not retain analysis")
    eq(weak[3],nil,"released Source does not retain declarations")
    print(string.format("[SpellHotReload scope facts] %d passed, 0 failed",passed))
    return {passed=passed,failed=0,failures={}}
end
return M
