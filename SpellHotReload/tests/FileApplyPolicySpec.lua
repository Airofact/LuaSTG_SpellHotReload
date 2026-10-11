-- Pure file policy tests: parse only, no candidate execution or fake joins.
-- Card target/cell/transaction integration remains in the existing real suites.
local M={}
function M.run()
    local FileApply=require("SpellHotReload.FileApply")
    local IR=require("SpellHotReload.Source.TopLevelIR")
    local Binding=require("SpellHotReload.Source.Binding")
    local passed,failed,failures=0,0,{}
    local function check(v,label)
        if v then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end
    end
    local function eq(a,b,label) check(a==b,label..": "..tostring(a).." ~= "..tostring(b)) end
    local function has(s,p,label) check(type(s)=="string" and s:find(p,1,true),label..": "..tostring(s)) end
    local function must(v,e) assert(v,type(e)=="table" and e.message or e);return v end
    local function scan(bytes)
        local nodes,err,analysis=IR.Analyze(bytes)
        assert(nodes,err)
        return {analysis=analysis,bindings=must(Binding.Analyze(analysis))}
    end
    local function side(bytes)
        return {scan=scan(bytes),excluded={},wiring="",binding_reads={}}
    end
    local function report(before,after)
        return {base={file="Policy_Boss.lua"},file_facts={before=side(before),after=side(after)}}
    end
    local function allowed(before,after,label)
        local r=report(before,after)
        local ok,err=FileApply.CheckTopLevel(r)
        eq(ok,true,label)
        eq(err,nil,label.." no refusal")
        return r
    end
    local function refused(before,after,label,pattern)
        local r=report(before,after)
        local ok,err=FileApply.CheckTopLevel(r)
        eq(ok,nil,label)
        eq(err and err.code,"unsupported",label.." code")
        has(err and err.message,pattern or "unbounded top-level change",label.." reason")
        eq(err and err.file,"Policy_Boss.lua",label.." file")
        return r,err
    end
    local saved_include=rawget(_G,"Include")
    local calls=0
    _G.Include=function() calls=calls+1;error("policy executed a candidate Include") end
    local card_name="SpellHotReload.CardVersions"
    local saved_card,saved_factory=package.loaded[card_name],package.preload[card_name]
    local card_requires=0
    package.loaded[card_name]=nil
    package.preload[card_name]=function()
        card_requires=card_requires+1;error("top-level policy must not depend on Card versions")
    end
    local ok,problem=pcall(function()
        allowed("KEEP()","KEEP()","unchanged opaque call")
        allowed("KEEP()","-- comment\nKEEP ( ) ;","opaque call formatting")
        allowed("KEEP()","\239\187\191KEEP()","BOM is not an executable change")
        for i,pair in ipairs({
            {"KEEP()","KEEP()\nInclude 'new.lua'"},
            {"KEEP()\nInclude 'old.lua'","KEEP()"},
            {"Include 'old.lua'\nKEEP()","Include('new.lua')\nKEEP()"},
            {"KEEP()\nInclude [[old.lua]]","KEEP()\nInclude [=[new.lua]=];"},
            {"Include 'old.lua'\nKEEP()","KEEP()\nInclude 'new.lua'"},
            {"Include 'a.lua'\nKEEP()\nInclude('b.lua')","Include 'c.lua'\nKEEP()"},
            {"KEEP()","Include \"new.lua\";\nKEEP()"},
        }) do
            allowed(pair[1],pair[2],"standalone Include policy "..i)
        end
        -- A declaration that is not yet in lexical scope does not shadow the
        -- preceding global Include. The declaration itself remains unchanged.
        allowed("Include 'old.lua'\nlocal Include",
            "Include 'new.lua'\nlocal Include","definition-point lexical visibility")
        for i,call in ipairs({
            "Include(path)","Include(helper())","Include('x.lua',helper())",
            "Include('x.lua'..suffix)","Include('x.lua')()",
            "loader.Include('x.lua')","loader:Include('x.lua')",
            "if true then Include 'x.lua' end","do Include 'x.lua' end",
            "Include 'x.lua'; UNREPLAYED_UNKNOWN()",
        }) do
            refused("KEEP()","KEEP()\n"..call,"nonstandalone Include "..i)
        end
        refused("local Include\nInclude 'old.lua'",
            "local Include\nInclude 'new.lua'","local loader shadow")
        refused("local function Include(p) return p end\nInclude 'old.lua'",
            "local function Include(p) return p end\nInclude 'new.lua'","local function shadow")
        refused("local alias=Include\nalias 'old.lua'",
            "local alias=Include\nalias 'new.lua'","loader alias")
        refused("KEEP()\nInclude 'old.lua'",
            "KEEP()\nInclude 'new.lua'\nGLOBAL_WRITE=1","Include does not erase another write")
        refused("KEEP()","KEEP()\n-- Include 'x.lua'\nOTHER()","comment does not claim effect")
        refused("GLOBAL_TEXT='Include old'","GLOBAL_TEXT='Include new'","string text is not a call")
        local _,point=refused("\239\187\191KEEP()",
            "\239\187\191CHANGED()","refusal range preserves BOM")
        has(point.message,"bytes 4-","BOM position")
        -- Exclusions are explicit adapter evidence, not discovered by this
        -- policy. Changed wiring remains a separate fact, not publication.
        local r=report("OWNED()\nKEEP()","CHANGED_OWNED()\nKEEP()")
        r.file_facts.before.excluded[1]=true
        r.file_facts.after.excluded[1]=true
        r.file_facts.before.wiring="old"
        r.file_facts.after.wiring="new"
        eq(FileApply.CheckTopLevel(r),true,"verified unrelated wiring can stay pending")
        r.file_facts.before.binding_reads[2]=true
        local value,err=FileApply.CheckTopLevel(r)
        eq(value,nil,"unchanged effect coupled to pending wiring refuses")
        has(err and err.message,"unbounded pending wiring binding","coupling reason")
        eq(err and err.code,"unsupported","coupling error code")
        r.file_facts.before.binding_reads[2]=nil
        r.file_facts.after.binding_reads[2]=true
        value,err=FileApply.CheckTopLevel(r)
        eq(value,nil,"candidate binding dependency also refuses")
        r.file_facts.before.wiring="same"
        r.file_facts.after.wiring="same"
        eq(FileApply.CheckTopLevel(r),true,"binding dependency without changed wiring is not a new refusal")
        r=report("OWNED()\nKEEP()","CHANGED_OWNED()\nCHANGED_KEEP()")
        r.file_facts.before.excluded[1]=true
        r.file_facts.after.excluded[1]=true
        value,err=FileApply.CheckTopLevel(r)
        eq(value,nil,"owned statement cannot mask neighboring unknown effect")
        has(err and err.message,"unbounded top-level change","neighbor effect reason")
        -- No blanket range or identity inference: changing the name of an
        -- unexcluded ordinary call is still a change even if arguments match.
        refused("UNKNOWN('A')","UNKNOWN('B')","opaque argument change")
        refused("UNKNOWN('A')","OTHER('A')","opaque callee change")
        for i,bad in ipairs({{}, {base={file="Policy_Boss.lua"}},
            {base={},file_facts={}}, {base={},file_facts={before={},after={}}}}) do
            value,err=FileApply.CheckTopLevel(bad)
            eq(value,nil,"incomplete evidence refused "..i)
            eq(err and err.code,"unsupported","incomplete evidence error "..i)
        end
        r=report("KEEP()","KEEP()")
        r.file_facts.before.excluded=nil
        value,err=FileApply.CheckTopLevel(r)
        eq(value,nil,"missing exclusions are not an empty proof")
        has(err and err.message,"statement evidence unavailable","missing evidence reason")
        eq(calls,0,"no Include or candidate chunk execution")
        eq(card_requires,0,"file policy independent of Card version implementation")
        eq(r.base.revision,nil,"policy does not invent a publication revision")
        eq(r.complete,nil,"preflight does not establish whole-file completion")
    end)
    rawset(_G,"Include",saved_include)
    package.loaded[card_name],package.preload[card_name]=saved_card,saved_factory
    if not ok then failed=failed+1;failures[#failures+1]="unexpected error: "..tostring(problem) end
    print(string.format("FileApplyPolicySpec: %d passed / %d failed",passed,failed))
    for _,why in ipairs(failures) do print("  FAIL "..why) end
    return {passed=passed,failed=failed}
end
return M
