-- Native parser ownership. Explicit GC belongs to lifecycle tests, not timings.
local M={}
local LIBRARY=".\\plugin\\SpellHotReload\\native\\dims_tree_sitter_lua.dll"
function M.run()
 local Native=require("SpellHotReload.Source.Native")
 local passed,failed,failures=0,0,{}
 local sessions,revisions,releases={},{},{}
 local function eq(a,b,label) assert(a==b,label);passed=passed+1 end
 local function check(v,label) assert(v,label);passed=passed+1 end
 local function open()
  local s=Native.Open(LIBRARY);sessions[#sessions+1]=s;return s
 end
 local function parse(s,text,prior)
  local r=s:Parse(text,prior);revisions[#revisions+1]=r;return r
 end
 local function hold(s)
  local release=assert(Native.Retain(s));releases[#releases+1]=release;return release
 end
 local function gc() for _=1,3 do collectgarbage("collect") end end
 local function case(name,fn)
  local ok,why=pcall(fn)
  if not ok then failed=failed+1;failures[#failures+1]=name..": "..tostring(why) end
 end
 case("independent source session remains open between parses",function()
  local s=open();local a=parse(s,"local x=1")
  local b=parse(s,"local x=2",a);local c=parse(s,"local x=3",b)
  eq(s.closed,false,"ordinary parse does not retire unleased session")
  eq(s.counts.parses,3,"three parses");eq(s.counts.incremental,2,"two updates")
  eq(a:Info(a:Root()).invalid,false,"first tree retained")
  s:Close();eq(s.counts.parsers,0,"explicit close releases parser")
  eq(c:Info(c:Root()).invalid,false,"tree readable after parser close")
 end)
 case("two owners share one parser without sharing retirement",function()
  local s=open();local r=parse(s,"return 1")
  local a,b=hold(s),hold(s)
  a();a();eq(s.closed,false,"one owner remains after idempotent release")
  b();eq(s.closed,true,"last owner closes");eq(s.counts.parsers,0,"closed once")
  eq(r:Info(r:Root()).invalid,false,"reader keeps old tree")
  eq(Native.Retain(s),nil,"retired parser cannot be retained")
  eq(pcall(s.Parse,s,"return 2",r),false,"retired parser cannot be previous")
 end)
 case("lost owner finalizer releases its count",function()
  local s=open();local r=parse(s,"return false")
  local lost=assert(Native.Retain(s));local kept=hold(s)
  lost=nil;gc()
  eq(s.closed,false,"remaining owner survives lost owner collection")
  kept();eq(s.closed,true,"lost count did not prevent last close")
  eq(r:Info(r:Root()).invalid,false,"reader survives lost owners")
 end)
 case("last lease release during parse defers native delete",function()
  local s=open();local prior=parse(s,"local x=1");local release=hold(s);local lib=s.lib
  s.lib=setmetatable({ts_tree_copy=function(pointer)
   release()
   eq(s.close_requested,true,"close requested during copy")
   eq(s.closed,false,"active parser not deleted")
   eq(s.counts.parsers,1,"parser retained through native call")
   eq(Native.Retain(s),nil,"closing parser cannot acquire a new owner")
   return lib.ts_tree_copy(pointer)
  end},{__index=function(_,key) return lib[key] end})
  local updated=parse(s,"local x=2",prior);s.lib=lib
  eq(s.active,0,"parse leaves active state")
  eq(s.closed,true,"pending close completed")
  eq(s.counts.parsers,0,"native parser deleted once")
  eq(prior:Info(prior:Root()).invalid,false,"prior tree stays readable")
  eq(updated:Info(updated:Root()).invalid,false,"result tree stays readable")
 end)
 case("parse error also completes pending close and preserves error",function()
  local s=open();local prior=parse(s,"return 1");local lib=s.lib;local marker={}
  s.lib=setmetatable({ts_parser_parse_string=function()
   s:Close();eq(s.closed,false,"failure still has active parser");error(marker,0)
  end},{__index=function(_,key) return lib[key] end})
  local ok,why=pcall(s.Parse,s,"return 2",prior);s.lib=lib
  eq(ok,false,"parse failure propagated");eq(why,marker,"same error object")
  eq(s.active,0,"failed parse leaves active state");eq(s.closed,true,"failure completes close")
  eq(s.counts.parsers,0,"failed parser closed once")
  eq(prior:Info(prior:Root()).invalid,false,"prior reader remains valid")
 end)
 case("same parser rejects reentrant parse",function()
  local s=open();local prior=parse(s,"return 1");local lib=s.lib
  s.lib=setmetatable({ts_tree_copy=function(pointer)
   local ok,why=pcall(s.Parse,s,"return 9",prior)
   eq(ok,false,"recursive parser call refused")
   check(tostring(why):find("parser already active",1,true),"busy diagnostic")
   return lib.ts_tree_copy(pointer)
  end},{__index=function(_,key) return lib[key] end})
  parse(s,"return 2",prior);s.lib=lib
  eq(s.active,0,"outer parse finishes");eq(s.counts.parses,2,"no nested native parse")
 end)
 case("foreign prior remains refused",function()
  local a,b=open(),open();local prior=parse(a,"return 1")
  eq(pcall(b.Parse,b,"return 2",prior),false,"different session prior refused")
  eq(b.active,0,"foreign refusal clears active state")
  eq(b.counts.parses,0,"foreign refusal did not parse")
 end)
 for _,release in ipairs(releases) do pcall(release) end
 for _,s in ipairs(sessions) do pcall(s.Close,s) end
 for _,r in ipairs(revisions) do pcall(r.Close,r) end
 for _,s in ipairs(sessions) do
  local ok,why=pcall(function()
   eq(s.counts.parsers,0,"all test parsers closed")
   eq(s.counts.trees,0,"unexposed test revisions closed")
  end)
  if not ok then failed=failed+1;failures[#failures+1]=tostring(why) end
 end
 for _,why in ipairs(failures) do print("[NativeOwnershipSpec] FAIL "..why) end
 return {passed=passed,failed=failed,failures=failures}
end
return M
