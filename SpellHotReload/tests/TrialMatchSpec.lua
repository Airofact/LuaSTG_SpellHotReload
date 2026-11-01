-- Real Native/Source discovery of variable-length Class and single-card units.
-- No analyzed source is executed; runtime publication is covered separately.
local M={}
function M.run()
    local Source=require("SpellHotReload.Source.FileAnalysis")
    local Syntax=require("SpellHotReload.Source.SyntaxTree")
    local Driver=require("SpellHotReload.Pipeline.Driver")
    local FileMatch=require("SpellHotReload.Pipeline.FileMatch")
    local Registry=require("SpellHotReload.Pipeline.NodeRegistry")
    local Local=require("SpellHotReload.Adapters.Local.Local")
    local Class=require("SpellHotReload.Adapters.Class.Class")
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local passed,failed,failures=0,0,{}
    local function eq(a,b,label) assert(a==b,label);passed=passed+1 end
    local function must(v,e) assert(v,type(e)=="table" and e.message or e);return v end
    local function case(label,body)
        local ok,err=xpcall(body,debug.traceback)
        if not ok then failed=failed+1;failures[#failures+1]=label..": "..tostring(err) end
    end
    local function discover(text)
        local source=must(Source.Build(text));local driver=Driver.New()
        for _,owner in ipairs({Local,Class,Card}) do must(driver:RegisterDiscovery(owner)) end
        local discovery,err=driver:Discover("Trial_Boss.lua",source)
        return discovery,err,source
    end
    local text=table.concat({
        "local f",
        "f=function() return 4 end",
        "_editor_class['K']=Class(boss)",
        "_editor_class['K'].cards={}",
        "_editor_class['K'].name='K'",
        "_editor_class['K'].init=function(self) self.n=f() end",
        "_tmp_sc=boss.card.New('A',1,2,3,100)",
        "function _tmp_sc:init() self.n=f() end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
        "local function between() return 7 end",
        "_tmp_sc=boss.card.New('B',1,2,3,100)",
        "_tmp_sc.init=function(self) self.n=between() end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
    },"\n")
    case("class prefix, independent cards and intervening Local",function()
        local d,e,source=discover(text);must(d,e)
        local s=d.snapshot;local cc=s.adapter_contexts.card;local cl=s.adapter_contexts.class
        eq(#s.units,5,"two Local, one Class, two single cards")
        eq(#cl.units,1,"one class definition unit")
        eq(cl.units[1].key,"class:K","class has its own identity")
        eq(cl.projection.by_key.K.writable,false,"boss recognition does not grant Object writes")
        eq(cl.projection.by_key.K.supported,true,"boss is recognized as a Class")
        eq(cl.units[1].source_ranges[1].first,source.analysis.statements[3].source_range.first,"class starts at constructor")
        eq(cl.units[1].source_ranges[1].last,source.analysis.statements[6].source_range.last,"class includes fields after cards initialization")
        eq(#cc.units,2,"same-class cards remain two public units")
        eq(#cc.classes,1,"class registration layout is private context")
        eq(cc.units[1].context.descriptor.name,"A","first card descriptor")
        eq(cc.units[2].context.descriptor.name,"B","second card descriptor")
        eq(cc.classes[1].layout[1].unit,cc.units[1],"layout references actual first candidate unit")
        eq(cc.classes[1].layout[2].unit,cc.units[2],"layout references actual second candidate unit")
        eq(cc.units[1].context.descriptor.last,9,"first card stops before Local")
        eq(s.by_key["local:between"].unit.context.name,"between","intervening Local was not swallowed")
        eq(#s.by_key["local:f"].unit.source_ranges,2,"later local assignment maps to the same binding unit")
        eq(#s.adapter_contexts["local"].projection.definitions.f,1,"definition context consumes accepted mapping")
        eq(s.by_key["card:K"],nil,"no class-sized Card wrapper survives")
        local local_definition,class_parts
        for _,mapping in ipairs(s.mappings) do
            if mapping.unit.key=="local:f" and mapping.data.definition then local_definition=mapping.data.definition end
            if mapping.unit.key=="class:K" then class_parts=mapping.data end
        end
        eq(s.adapter_contexts["local"].projection.definitions.f[1],local_definition,"Local context retains the matched definition object")
        eq(cl.projection.by_key.K.constructor,class_parts[1],"Class context retains the matched constructor object")
        eq(cl.projection.by_key.K.members[1],class_parts[2],"Class context retains the matched member object")
        eq(s.sequence[3].adapter,Class,"accepted Class result remains in source order")
        eq(s.sequence[3].mappings[1].data,class_parts,"ordered result retains the same Class descriptions")
        eq(s.sequence[4].units[1],cc.units[1],"card follows its class definition")
        eq(s.sequence[5].adapter,Local,"intervening Local stays between cards")
        eq(s.sequence[6].units[1],cc.units[2],"second card keeps its original accepted position")
        eq(cc.units[1].context.descriptor.registrations[1].class_key,"K","Card retains its matched registration target")
        eq(cc.units[1].context.descriptor.registrations[1].index,9,"registration records source order, not a guessed slot")

        local build,parse=Source.Build,Syntax.Parse
        Source.Build=function() error("discovery rebuilt Source") end
        Syntax.Parse=function() error("discovery reparsed input") end
        local ok,value,problem=pcall(d.owner.Discover,d.owner,"Trial_Boss.lua",source)
        Source.Build,Syntax.Parse=build,parse
        must(ok,value);must(value,problem);eq(value.source,source,"discovery reuses exact full source")
    end)
    case("failed multi-item trial restores the shared cursor",function()
        local source=must(Source.Build("local a,b=1,2\nG=3\nH=4"))
        local registry=Registry.New();local seen,built={},0;local accepted_result
        local function no() error("publication hook ran") end
        local function adapter(id,match)
            return {Id=id,ContractVersion=7,Match=match,
                BuildContext=function(s,u) built=built+1;return {source=s,units=u} end,
                Reconcile=no,Locate=no,Inject=no,Commit=no}
        end
        must(registry:RegisterDiscovery(adapter("first",function(c)
            local mark=c:Mark();c:Take();if mark==1 then c:Take() end;return nil
        end)))
        must(registry:RegisterDiscovery(adapter("second",function(c,common,accepted)
            seen[#seen+1]=c:Mark();eq(common.source,source,"trial has full lexical source")
            if c:Mark()~=1 then return nil end
            local a={key="a",carrier="local",context={}};local b={key="b",carrier="local",context={}}
            c:Take();eq(built,0,"units returned before file-context assembly")
            accepted_result={units={a,b},claims={},mappings={{unit=a,first=1,last=1},{unit=b,first=1,last=1}}}
            return accepted_result
        end)))
        local s=must(FileMatch.Discover(registry,source,{file="Trial.lua"}))
        eq(table.concat(seen,","),"1,2,3","every losing trial restored its starting point")
        eq(#s.units,2,"multi-name syntax may produce two units")
        eq(#s.unmatched,2,"unmatched items remain available to completion checks")
        eq(#s.sequence,3,"only accepted results and unmatched statements enter the sequence")
        eq(s.sequence[1],accepted_result,"the original accepted Match result is reused")
        eq(s.sequence[2],2,"first unmatched statement retains its source position")
        eq(s.sequence[3],3,"second unmatched statement follows it without sorting")
    end)
    case("single-card scope rejects detached callbacks",function()
        local input=text:gsub("function _tmp_sc:init%(%) self.n=f%(%) end", "local gap=1\nfunction _tmp_sc:init() self.n=f() end",1)
        local d,err=discover(input)
        eq(d,nil,"no EOF replay attaches a callback across a Local item")
        eq(err.code,"unsupported","detached card grammar is explicit")
    end)
    case("one card can have multiple syntax registrations without duplicate units",function()
        local input=text:gsub("table.insert%(_editor_class%['K'%]%.cards,_tmp_sc%)",function(line) return line.."\n"..line end,1)
        local d,e=discover(input);must(d,e)
        local cc=d.snapshot.adapter_contexts.card
        eq(#cc.units,2,"two constructor blocks remain two cards")
        eq(#cc.units[1].context.placements,2,"reused slot relation is preserved for live ownership refusal")
        eq(cc.classes[1].layout[1],cc.classes[1].layout[2],"shared descriptor identity is not flattened")
    end)
    case("BOM and CRLF retain original byte ranges",function()
        local input="\239\187\191"..text:gsub("\n","\r\n")
        local d,e,source=discover(input);must(d,e)
        local first=d.snapshot.by_key["local:f"].unit.source_ranges[1]
        eq(first.first,4,"BOM remains in file coordinates")
        eq(input:sub(first.first,first.last),"local f","native range selects exact original statement")
        eq(source.content,input,"complete original input retained")
    end)
    case("unregistered card is an observation, not a class or published provider",function()
        local d,e=discover("_tmp_sc=boss.card.New('Loose',1,2,3,100)\nfunction _tmp_sc:init() end");must(d,e)
        local cc=d.snapshot.adapter_contexts.card
        eq(#cc.units,1,"single card still has an immediate discovery unit")
        eq(#cc.classes,0,"no registry class was invented")
        eq(#cc.units[1].context.placements,0,"no registration was guessed")
    end)
    return {passed=passed,failed=failed,failures=failures}
end
return M
