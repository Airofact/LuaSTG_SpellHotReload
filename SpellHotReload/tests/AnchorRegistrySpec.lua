-- First-load ownership, read-only live cells, missing-file retention and release.
local M={}
function M.run()
    local Load=require("SpellHotReload.Load.AnchorLoad")
    local Registry=require("SpellHotReload.Load.AnchorRegistry")
    local passed=0
    local function eq(a,b,label) assert(a==b,label);passed=passed+1 end
    local source=[[local counter=0
local flag=false
local empty
local config={a=1}
local helper=function() return counter end
local function set(v) counter=v end
local function reset() config={a=2};helper=function() return 9 end end
local function read() return counter,config,helper end]]
    local function capture()
        return assert(Load.Capture(source,{name="Registry_Boss.lua",
            capability={getupvalue=true,setupvalue=true,upvaluejoin=true}}))
    end
    local reg=Registry.New()
    eq(reg:Set("",{}),false,"empty key refused")
    eq(reg:Set("A",{}),false,"partial entry refused")
    local entry=capture()
    eq(reg:Set("B",entry),true,"complete entry registered")
    eq(reg:Set("B",entry),true,"same anchor idempotent")
    eq(reg:Set("B",capture()),false,"replacement anchor refused")
    eq(reg:Entry("B"),entry,"entry identity")
    eq(reg:Anchor("B"),entry.anchor,"anchor identity")
    eq(reg:Slots("B"),entry.slots,"slots identity")
    eq(reg:GetSource("B"),source,"first-load bytes")
    eq(reg:GetValue("B","flag"),false,"false captured")
    local value,reason=reg:GetValue("B","empty")
    eq(value,nil,"nil captured");eq(reason,nil,"nil is a present cell")
    value,reason=reg:GetValue("B","absent")
    eq(value,nil,"absent value");eq(type(reason),"string","absent diagnostic")
    eq(reg:Slot("B","empty"),entry.slots.empty,"nil has a slot")
    eq(reg:Slot("B","absent"),nil,"unknown has no slot")
    eq(table.concat(reg:Names("B"),","),"config,counter,empty,flag,helper,read,reset,set","only actual slots named")
    entry.map.set(7)
    eq(reg:GetValue("B","counter"),7,"external setter observed live")
    eq(entry.map.counter,0,"load-time scalar remains evidence")
    local original=reg:GetValue("B","helper")
    entry.map.reset()
    eq(reg:GetValue("B","config").a,2,"table replacement observed")
    eq(reg:GetValue("B","helper")(),9,"function replacement observed")
    eq(original(),7,"original outside consumer survives")
    eq(reg:Set("A",capture()),true,"second file registered")
    eq(table.concat(reg:Files(),","),"A,B","files sorted")
    eq(reg:Size(),2,"size")
    eq(reg:Live("B"),true,"captured reloadable")
    eq(reg:Missing("B"),true,"missing marks entry")
    eq(reg:Live("B"),false,"missing refuses reload")
    eq(reg:GetValue("B","counter"),7,"missing retains cells")
    eq(reg:GetSource("B"),source,"missing retains bytes")
    eq(reg:Missing("unknown"),false,"unknown missing refused")
    eq(reg:Release(),true,"release succeeds")
    eq(reg:Release(),true,"release idempotent")
    eq(reg:Entry("B"),nil,"release drops entry")
    eq(reg:GetSource("B"),nil,"release drops bytes")
    eq(reg:Size(),0,"release empties registry")
    eq(original(),7,"release preserves outside consumer")
    return {passed=passed,failed=0}
end
return M
