-- Product first-load -> incremental Build -> retirement. No engine or Apply timing.
local M={}
function M.run()
 local Source=require("SpellHotReload.Source.FileAnalysis")
 local Tree=require("SpellHotReload.Source.SyntaxTree")
 local Native=require("SpellHotReload.Source.Native")
 local Capture=require("SpellHotReload.Load.AnchorLoad")
 local Anchor=require("SpellHotReload.Load.Anchor")
 local globals={"lstg","boss","_editor_class","_sc_table","_tmp_sc","ext","stage"}
 local saved={};for _,key in ipairs(globals) do saved[key]=rawget(_G,key) end
 local names={"lstg.FileSystemWatcher","lstg.FileSystemWatcher.FileAction",
  "SpellHotReload.Runtime.Watcher","SpellHotReload.Runtime.Plugin"}
 local loaded={};for _,name in ipairs(names) do loaded[name]=package.loaded[name] end
 package.loaded[names[1]],package.loaded[names[2]]={},{}
 package.loaded[names[3]],package.loaded[names[4]]=nil,nil
 local Plugin=require("SpellHotReload.Runtime.Plugin")
 local original_open,original_retain,original_build=Native.Open,Native.Retain,Source.Build
 local opened,retained,plugins={},{},{}
 Native.Open=function(...)
  local s=original_open(...);opened[#opened+1]=s;return s
 end
 Native.Retain=function(s)
  local release,why=original_retain(s)
  if release then retained[#retained+1]=s end
  return release,why
 end
 local passed,failed,failures=0,0,{}
 local function eq(a,b,label) assert(rawequal(a,b),label);passed=passed+1 end
 local function check(v,label) assert(v,label);passed=passed+1 end
 local function must(v,why) assert(v,type(why)=="table" and why.message or why);return v end
 local function plugin()
  local p=Plugin.New();plugins[#plugins+1]=p;return p
 end
 local function entry(text,file) return must(Capture.Capture(text,{name=file})) end
 local function adopt(p,file,e)
  must(p:AdoptLoad(file,e))
  local record=assert(p._parse_baselines[file])
  eq(record.entry,e,"record owns exact first-load entry")
  return record,retained[#retained]
 end
 local function case(name,fn)
  local ok,why=pcall(fn)
  Source.Build=original_build
  if not ok then failed=failed+1;failures[#failures+1]=name..": "..tostring(why) end
 end
 lstg={Log=function() end};boss=nil;_editor_class=nil;_sc_table={};_tmp_sc=nil
 ext={replay={IsReplay=function() return false end}}
 local text="local counter=3\nlocal function helper(n) return counter+n end"
 case("normal first load and six continuous updates",function()
  local p=plugin();local e=entry(text,"A_Boss.lua");local record,s=adopt(p,"A_Boss.lua",e)
  local first=e.source;local publication=p:GetVersions("A_Boss.lua").snapshot
  local history={{source=first,content=text}};local previous=first
  eq(record.source,first,"first load seeds incremental parser")
  for i=1,6 do
   local content=text:gsub("counter%+n","counter+n+"..i)
   local current=must(p:_BuildCandidate("A_Boss.lua",content))
   eq(record.source,current,"successful Build advances only parse baseline")
   eq(e.source,first,"original first-load Source is unchanged")
   eq(e.loaded_source,text,"original loaded bytes are unchanged")
   eq(s.counts.parses,i+1,"same parser for whole seven-input fixture")
   eq(s.counts.incremental,i,"consecutive incremental count")
   for _,old in ipairs(history) do
    check(Source.Validate(old.source),"old Source provenance remains valid")
    eq(Tree.Text(old.source.analysis.syntax),old.content,"old snapshot text preserved")
    eq(table.concat(old.source.bindings.names,","),"counter,helper","old bindings preserved")
   end
   eq(p:GetVersions("A_Boss.lua").snapshot,publication,"analysis does not publish versions")
   eq(Anchor.Get(e,"helper")(2),5,"analysis does not replace live helper")
   if i==3 then
    local bad,why=p:_BuildCandidate("A_Boss.lua","local =")
    eq(bad,nil,"compile failure refused");eq(why.code,"compile","compile diagnostic preserved")
    eq(record.source,current,"failed analysis does not advance baseline")
    eq(s.counts.parses,i+1,"compile refusal never parses")
   end
   history[#history+1]={source=current,content=content};previous=current
  end
  local b=entry("local other=8\nlocal function helper() return other end","B_Boss.lua")
  local _,other=adopt(p,"B_Boss.lua",b);check(s~=other,"other file has another parser")
  must(p:_BuildCandidate("B_Boss.lua","local other=9\nlocal function helper() return other end"))
  eq(other.counts.incremental,1,"other file has its own previous")
  eq(s.counts.incremental,6,"other file never consumes A history")
  p:StopWatching();eq(s.closed,false,"StopWatching retains parser")
  p:Release("done");eq(s.closed,true,"release closes A parser");eq(other.closed,true,"release closes B parser")
  eq(Tree.Text(previous.analysis.syntax),history[#history].content,"reader survives Plugin release")
 end)
 case("same entry shared by two Plugins",function()
  local e=entry(text,"Shared_Boss.lua");local a,b=plugin(),plugin()
  local _,sa=adopt(a,"Shared_Boss.lua",e);local _,sb=adopt(b,"Shared_Boss.lua",e)
  eq(sa,sb,"same Source leases one native parser")
  a:Release();eq(sa.closed,false,"one Plugin cannot close the other's parser")
  must(b:_BuildCandidate("Shared_Boss.lua",text:gsub("counter%+n","counter+n+8")))
  eq(sa.counts.incremental,1,"remaining Plugin can update")
  b:Release();eq(sa.closed,true,"last Plugin closes parser")
  check(Source.Validate(e.source),"shared reader remains valid")
  eq(Source.Retain(e.source),nil,"retired first-load parser cannot be reopened")
  local rejected=Source.Build(text,nil,e.source)
  eq(rejected,nil,"retired Source cannot seed a new mutable session")
 end)
 case("both owners retire an already missing shared entry",function()
  local e=entry(text,"Missing_Boss.lua");local a,b=plugin(),plugin()
  local _,s=adopt(a,"Missing_Boss.lua",e);adopt(b,"Missing_Boss.lua",e)
  must(a:Missing("Missing_Boss.lua"));eq(s.closed,false,"other lease remains")
  must(b:Missing("Missing_Boss.lua"));eq(s.closed,true,"early missing path retires this lease")
  eq(a._parse_baselines["Missing_Boss.lua"],nil,"A baseline removed")
  eq(b._parse_baselines["Missing_Boss.lua"],nil,"B baseline removed")
  must(b:AdoptLoad("Missing_Boss.lua",e))
  eq(b._parse_baselines["Missing_Boss.lua"],nil,"idempotent adoption cannot resurrect missing source")
  eq(Tree.Text(e.source.analysis.syntax),text,"missing retains readable first-load evidence")
 end)
 case("duplicate execution retires only original parse history",function()
  local p=plugin();local old=entry(text,"Again_Boss.lua");local _,s=adopt(p,"Again_Boss.lua",old)
  local newer=entry(text,"Again_Boss.lua")
  local accepted=p:AdoptLoad("Again_Boss.lua",newer)
  eq(accepted,false,"duplicate execution still refused")
  eq(p:GetLoad("Again_Boss.lua"),old,"first entry kept")
  eq(p._parse_baselines["Again_Boss.lua"],nil,"duplicate drops parse baseline")
  eq(s.closed,true,"duplicate retires original parser")
  eq(Tree.Text(old.source.analysis.syntax),text,"duplicate keeps original read evidence")
 end)
 case("failed execution without Source remains an authoritative record",function()
  local p=plugin();local broken={loaded_source="error('failed')",reloadable=false,failed=true,phase="run",reason="failed"}
  must(p:AdoptLoad("Broken_Boss.lua",broken))
  eq(p:GetLoad("Broken_Boss.lua"),broken,"failed-load record retained")
  eq(p._parse_baselines["Broken_Boss.lua"],nil,"no Source invented")
  eq(broken.reason,"failed","original execution error retained")
 end)
 case("active transaction refusal does not release parser ownership",function()
  local p=plugin();local e=entry(text,"Active_Boss.lua");local _,s=adopt(p,"Active_Boss.lua",e)
  local original=p._commit.Release;p._commit.Release=function() return nil,"active" end
  local released,why=p:Release()
  eq(released,nil,"active transaction blocks release");eq(why,"active","transaction error preserved")
  eq(p:IsReleased(),false,"Plugin remains active");eq(s.closed,false,"parser ownership retained")
  p._commit.Release=original;must(p:Release());eq(s.closed,true,"later release closes parser")
 end)
 case("retirement during Build cannot resurrect parse baseline",function()
  local p=plugin();local e=entry(text,"During_Boss.lua");local _,s=adopt(p,"During_Boss.lua",e)
  local made
  Source.Build=function(...)
   made=must(original_build(...));p:Missing("During_Boss.lua");return made
  end
  local source,why=p:_BuildCandidate("During_Boss.lua",text:gsub("counter%+n","counter+n+9"))
  eq(source,nil,"retired Build result not retained");eq(why.code,"stale","retirement diagnostic")
  eq(p._parse_baselines["During_Boss.lua"],nil,"baseline stays retired")
  eq(s.closed,true,"retirement closes parser")
  check(Tree.Text(made.analysis.syntax):find("counter+n+9",1,true),"returned tree remains readable")
 end)
 case("release during adoption cannot resurrect a Plugin",function()
  local p=plugin();local e=entry(text,"Adopt_Boss.lua");local retain=Native.Retain;local s
  Native.Retain=function(parser)
   s=parser;local release,why=retain(parser);p:Release();return release,why
  end
  local called,accepted=pcall(p.AdoptLoad,p,"Adopt_Boss.lua",e)
  Native.Retain=retain
  eq(called,true,"adoption retirement does not throw into completed load")
  eq(accepted,false,"adoption after release refused")
  eq(p:GetLoad("Adopt_Boss.lua"),nil,"ended Plugin stays empty")
  eq(p._parse_baselines["Adopt_Boss.lua"],nil,"no parse baseline resurrection")
  eq(s.closed,true,"unused lease released")
 end)
 case("same-byte Source replacement during adoption cannot mix parser ownership",function()
  local p=plugin();local e=entry(text,"Replaced_Boss.lua")
  local original=e.source;local replacement=must(Source.Build(text));local retain=Native.Retain;local s
  Native.Retain=function(parser)
   s=parser;local release,why=retain(parser);e.source=replacement;return release,why
  end
  local called,accepted=pcall(p.AdoptLoad,p,"Replaced_Boss.lua",e)
  Native.Retain=retain
  eq(called,true,"replacement does not throw into completed load")
  eq(accepted,false,"changed Source identity refused even with identical bytes")
  eq(p:GetLoad("Replaced_Boss.lua"),nil,"changed entry not adopted")
  eq(p._parse_baselines["Replaced_Boss.lua"],nil,"mismatched baseline never installed")
  eq(s.closed,true,"unused original parser lease released")
  eq(Tree.Text(original.analysis.syntax),text,"original read evidence survives refusal")
  local release=must(Source.Retain(replacement));release()
 end)
 case("shared Missing during adoption cannot revive a retired entry",function()
  local e=entry(text,"AdoptMissing_Boss.lua");local a,b=plugin(),plugin()
  local _,s=adopt(a,"AdoptMissing_Boss.lua",e);local retain=Native.Retain
  Native.Retain=function(parser)
   local release,why=retain(parser);a:Missing("AdoptMissing_Boss.lua");return release,why
  end
  local called,accepted=pcall(b.AdoptLoad,b,"AdoptMissing_Boss.lua",e)
  Native.Retain=retain
  eq(called,true,"shared retirement does not throw into completed load")
  eq(accepted,false,"missing entry not adopted after allocation")
  eq(b:GetLoad("AdoptMissing_Boss.lua"),nil,"second Plugin keeps no retired load")
  eq(a._parse_baselines["AdoptMissing_Boss.lua"],nil,"first Plugin baseline retired")
  eq(b._parse_baselines["AdoptMissing_Boss.lua"],nil,"second baseline never installed")
  eq(s.closed,true,"both leases released after shared Missing")
  check(Source.Validate(e.source),"read evidence survives shared retirement")
 end)
 case("unknown-file discovery still receives analysis without retained history",function()
  local p=plugin();local count=#opened
  local source=must(p:_BuildCandidate("Unknown_Boss.lua",text))
  check(Source.Validate(source),"unknown file still analyzed")
  eq(p:GetLoad("Unknown_Boss.lua"),nil,"analysis cannot manufacture first load")
  eq(p._parse_baselines["Unknown_Boss.lua"],nil,"unknown Source not retained as baseline")
  eq(#opened,count+1,"unknown native parse is independent")
 end)
 Source.Build=original_build;Native.Retain=original_retain;Native.Open=original_open
 for _,p in ipairs(plugins) do pcall(p.Release,p,"spec cleanup") end
 for _,s in ipairs(opened) do pcall(s.Close,s) end
 for _,key in ipairs(globals) do rawset(_G,key,saved[key]) end
 for _,name in ipairs(names) do package.loaded[name]=loaded[name] end
 for _,why in ipairs(failures) do print("[IncrementalSourceSpec] FAIL "..why) end
 return {passed=passed,failed=failed,failures=failures}
end
return M
