-- Dependency retirement and exact legacy compatibility; no game source runs.
-- All closures/tables are synthetic. This is a regression spec, not a Probe.
local M = {}
function M.run()
    local passed, failed, failures = 0, 0, {}
    local function check(v, label)
        if v then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end
    end
    local function eq(a,b,label) check(a==b,label) end
    local function has(s,part,label)
        check(type(s)=="string" and s:find(part,1,true)~=nil,label)
    end
    local function case(label,fn)
        local ok,err=pcall(fn)
        if not ok then check(false,label..": "..tostring(err)) end
    end
    local prefix="SpellHotReload."
    local function belongs(key)
        return type(key)=="string" and key:sub(1,#prefix)==prefix
    end
    local saved_loaded={}
    for key,value in pairs(package.loaded) do
        if belongs(key) then saved_loaded[key]=value end
    end
    for key in pairs(saved_loaded) do package.loaded[key]=nil end
    local loader_name=prefix.."GeneratedBossLoader"
    local functions_name=prefix.."Legacy.Functions"
    local watcher_name=prefix.."Watcher"
    local saved_preload=package.preload[loader_name]
    local globals={"lstg","boss","stage","_editor_class","_tmp_sc","_legacy34_effect"}
    local saved_globals={}
    for _,key in ipairs(globals) do saved_globals[key]=rawget(_G,key) end
    local original_get, original_set, original_join=debug.getupvalue,debug.setupvalue,debug.upvaluejoin
    local old_exit=os.exit
    local forbidden_calls=0
    local function forbidden()
        forbidden_calls=forbidden_calls+1
        error("legacy loader dependency forbidden")
    end
    package.preload[loader_name]=forbidden
    -- Avoid engine-only watcher bindings in the synthetic cold Plugin graph.
    package.loaded[watcher_name]={}
    local F,Value,Host,Callbacks,original_build,original_extract
    case("cold adapter graph without loader or legacy construction",function()
        local Driver=require(prefix.."Driver")
        local Plugin=require(prefix.."Plugin")
        local instance=Plugin.New()
        eq(type(Driver.New()),"table","generic driver cold load")
        eq(instance:IsReleased(),false,"plugin cold lifecycle")
        eq(package.loaded[loader_name],nil,"Plugin already independent of legacy loader")
        eq(package.loaded[functions_name],nil,"Plugin does not load legacy constructors")
        Value=require(prefix.."Value")
        Host=require(prefix.."Host")
        Callbacks=require(prefix.."CardCallbacks")
        eq(package.loaded[loader_name],nil,"all adapters independent of hook facade")
        eq(package.loaded[functions_name],nil,"Value/Host/read-only Card do not construct functions")
        eq(type(Value.Parse({text="local x = false",carrier="local",slot=1,name="x"})),"table","Value direct lexer")
        eq(type(Host.Parse({text="stage.group.DefStageFunc('S', 'frame', function() end)"})),"table","Host direct lexer")
        eq(package.loaded[functions_name],nil,"parsing does not load legacy constructors")
        check(instance:Release(),"cold plugin releases")
    end)
    case("legacy utility namespace has no hook or Probe",function()
        F=require(functions_name)
        original_build,original_extract=F.BuildFunction,F.ExtractFunction
        eq(type(F.ListFunctionNames),"function","names entry")
        eq(type(F.ExtractFunction),"function","fragment entry")
        eq(type(F.BuildFunction),"function","value builder entry")
        for _,key in ipairs({"Probe","InstallDoFileHook","BuildTrailer","Tokenize","Release","SetAll"}) do
            eq(F[key],nil,"utility does not own "..key)
        end
        eq(package.loaded[loader_name],nil,"utility never requires facade")
    end)
    case("legacy enumeration and exact fragment boundaries",function()
        local frag="local function f(n) if n then for i=1,2 do n=n+i end end return 'end' end"
        local source="-- function fake() end\nlocal function g() end\n"..frag.."\nlocal function f() end\nwire()"
        local names=F.ListFunctionNames(source)
        eq(#names,2,"deduplicated legacy declaration names")
        eq(names[1],"g","name order first")
        eq(names[2],"f","name order second")
        eq(F.ExtractFunction(source,"f"),frag,"first legacy matching fragment exact")
        eq(F.ExtractFunction("\239\187\191"..source,"f"),frag,"BOM removed only for extraction")
        eq(F.ExtractFunction(source,"missing"),nil,"missing fragment")
        eq(F.ExtractFunction("local function bad(","bad"),nil,"unfinished declaration")
        eq(F.ExtractFunction(4,"f"),nil,"non-string source")
        eq(F.ExtractFunction(source,4),nil,"non-string name")
        eq(#F.ListFunctionNames(nil),0,"nil names source")
        eq(#F.ListFunctionNames("--[=[ local function fake() end ]=]"),0,"long-comment name excluded")
        local nested="local function outer() local function inner() end end"
        eq(#F.ListFunctionNames(nested),1,"nested function excluded")
        eq(F.ExtractFunction(nested,"inner"),nil,"nested extraction excluded")
        eq(F.ListFunctionNames("\239\187\191"..nested)[1],"outer","BOM name enumeration")
    end)
    case("preserved value-map semantics, not shared Anchor cells",function()
        _legacy34_effect=0
        local map={n=3,flag=false,box={value=5},sibling=function(n) return n*2 end}
        local fragment="local function f() _legacy34_effect=_legacy34_effect+1;return sibling(n),flag,box end"
        local fn=assert(F.BuildFunction(fragment,"f",map))
        eq(_legacy34_effect,0,"factory does not call function body")
        local a,b,c=fn()
        eq(a,6,"injected sibling and scalar")
        eq(b,false,"injected false value")
        eq(c,map.box,"injected table identity")
        eq(_legacy34_effect,1,"explicit test invokes body once")
        map.n=9
        eq(fn(),6,"legacy map reassignment does not share a cell")
        local recursive=assert(F.BuildFunction("local function fact(n) if n==0 then return 1 end return n*fact(n-1) end","fact",{}))
        eq(recursive(5),120,"legacy local recursion preserved")
        local bare=assert(F.BuildFunction("local function f() return 7 end","f",nil))
        eq(bare(),7,"no registry compatibility")
        eq(map.flag,false,"builder does not rewrite map")
    end)
    case("legacy builder error results remain compatible",function()
        for _,args in ipairs({{false,"f"},{ "local function f() end",false}}) do
            local fn,err=F.BuildFunction(args[1],args[2],{})
            eq(fn,nil,"invalid inputs rejected")
            has(err,"fragment or name is not a string","invalid input diagnostic")
        end
        local fn,err=F.BuildFunction("local function f(","f",{})
        eq(fn,nil,"compile error rejected");has(err,"compile fragment failed","compile diagnostic")
        fn,err=F.BuildFunction("local function f() end\nerror('factory-test-error')","f",{})
        eq(fn,nil,"factory error rejected");has(err,"fragment execution failed","factory diagnostic")
        fn,err=F.BuildFunction("local f=1","f",{})
        eq(fn,nil,"non-function return rejected");has(err,"fragment did not produce a function","type diagnostic")
    end)
    case("Value legacy local-function path delegates without old loader",function()
        Value=Value or require(prefix.."Value")
        local calls={extract=0,build=0}
        F.ExtractFunction=function(...) calls.extract=calls.extract+1;return original_extract(...) end
        F.BuildFunction=function(...) calls.build=calls.build+1;return original_build(...) end
        local node={kind="function",carrier="local",name="f",text="local function f() return n+1 end"}
        local handle=assert(Value.Locate(node,{}))
        local plan=assert(Value.Inject(handle,node,{content=node.text,working={n=8}}))
        eq(calls.extract,1,"Value uses extracted legacy fragment")
        eq(calls.build,1,"Value uses legacy value builder")
        eq(plan.value(),9,"Value callback compatible")
        local map={}
        check(Value.Commit(handle,plan,{map=map}),"explicit legacy map commit")
        eq(map.f,plan.value,"legacy map target assigned")
        eq(package.loaded[loader_name],nil,"Value.Inject never loads old facade")
        F.BuildFunction,F.ExtractFunction=original_build,original_extract
    end)
    case("Card historical Build delegates without old loader",function()
        Callbacks=Callbacks or require(prefix.."CardCallbacks")
        local calls={extract=0,build=0}
        F.ExtractFunction=function(...) calls.extract=calls.extract+1;return original_extract(...) end
        F.BuildFunction=function(...) calls.build=calls.build+1;return original_build(...) end
        local defaults={}
        for _,name in ipairs({"before","init","frame","render","beforedel","del","after"}) do defaults[name]=function() end end
        boss={card={_default_card=defaults}}
        local helper=function() return 1 end
        local live={name="Card"}
        for name,fn in pairs(defaults) do live[name]=fn end
        live.init=function(self) self.value=helper() end
        local old_init=live.init
        local source="local function helper() return 2 end"
        local descriptor={locals={helper=true},callbacks={init="function(self) self.value=helper() end"}}
        local plan=assert(Callbacks.Build(descriptor,live,source,{helper=helper}))
        eq(calls.extract,1,"Card uses legacy extractor")
        eq(calls.build,1,"Card uses legacy builder")
        eq(live.init,old_init,"Build leaves live callback unchanged")
        local before={};live.init(before);eq(before.value,1,"old body retained before publish")
        local after={};plan.callbacks.init(after);eq(after.value,2,"new body compiled")
        eq(plan.callbacks.frame,defaults.frame,"optional default retained")
        eq(package.loaded[loader_name],nil,"Card.Build never loads old facade")
        F.BuildFunction,F.ExtractFunction=original_build,original_extract
    end)
    case("Host parse/Inject directly uses shared lexer",function()
        Host=Host or require(prefix.."Host")
        local node={text="stage.group.DefStageFunc('S', 'frame', function(self) self.value=7 end)",carrier="host"}
        local handle=assert(Host.Locate(node,{}))
        local plan=assert(Host.Inject(handle,node,{map={}}))
        eq(type(plan),"table","legacy Host plan")
        eq(package.loaded[loader_name],nil,"Host parse/inject never loads facade")
    end)
    case("historical facade delegates, hook compatibility remains",function()
        package.preload[loader_name]=saved_preload
        package.loaded[loader_name]=nil
        local Loader=require(loader_name)
        eq(type(Loader.InstallDoFileHook),"function","old hook remains isolated compatibility")
        eq(Loader.Probe,nil,"no behavioral Probe restored")
        local extract_args,build_args
        F.ExtractFunction=function(...) extract_args={...};return "extracted","reason" end
        F.BuildFunction=function(...) build_args={...};return "built","reason" end
        local a,b=Loader.ExtractFunction("source","f")
        eq(a,"extracted","facade extractor return");eq(b,"reason","facade second return")
        eq(extract_args[1],"source","extract source forwarded");eq(extract_args[2],"f","extract name forwarded")
        local registry={}
        a,b=Loader.BuildFunction("fragment","f",registry)
        eq(a,"built","facade builder return");eq(b,"reason","facade builder second return")
        eq(build_args[1],"fragment","fragment forwarded");eq(build_args[2],"f","name forwarded")
        eq(build_args[3],registry,"map reference forwarded")
        F.BuildFunction,F.ExtractFunction=original_build,original_extract
        eq(Loader.ListFunctionNames("local function f() end")[1],"f","facade names delegated")
        local Lexer=require(prefix.."Lexer")
        local Capture=require(prefix.."LoadCapture")
        eq(#Loader.Tokenize("local x=1"),#Lexer.Tokenize("local x=1"),"facade lexer delegates")
        eq(Loader.BuildTrailer({"a","b"}),Capture.Trailer({"a","b"}),"facade trailer delegates")
    end)
    eq(forbidden_calls,0,"no adapter attempted legacy Loader import")
    -- Restore even after failed cases so same-VM regression suites stay isolated.
    if F and original_build then F.BuildFunction,F.ExtractFunction=original_build,original_extract end
    debug.getupvalue,debug.setupvalue,debug.upvaluejoin=original_get,original_set,original_join
    os.exit=old_exit
    for _,key in ipairs(globals) do rawset(_G,key,saved_globals[key]) end
    package.preload[loader_name]=saved_preload
    local to_clear={}
    for key in pairs(package.loaded) do if belongs(key) then to_clear[#to_clear+1]=key end end
    for _,key in ipairs(to_clear) do package.loaded[key]=nil end
    for key,value in pairs(saved_loaded) do package.loaded[key]=value end
    for _,label in ipairs(failures) do print("FAIL LegacyFunctionsSpec: "..label) end
    print(string.format("LegacyFunctionsSpec: %d passed / %d failed",passed,failed))
    return {passed=passed,failed=failed,failures=failures}
end
return M
