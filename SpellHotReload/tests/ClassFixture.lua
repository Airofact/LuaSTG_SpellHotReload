-- Offline Class API stand-in. ClassLoad must observe the caller's real load;
-- this module never creates source history, versions or publication authority.
local M={}
local callbacks={"init","del","frame","render","colli","kill"}
local bases={"_object","bullet","enemy","laser","laser_bent","boss"}
local globals={"Class","object","_object","bullet","enemy","laser","laser_bent",
    "boss","all_class","_editor_class","_tmp_sc","_sc_table"}
function M.Install()
    local saved={};for _,name in ipairs(globals) do saved[name]=rawget(_G,name) end
    local classes={}
    _G.all_class=classes;_G._editor_class={};_G._tmp_sc=nil;_G._sc_table={}
    _G.Class=function(parent)
        assert(type(parent)=="table" and parent.is_class)
        local cls={0,0,0,0,0,0,is_class=true,base=parent}
        for _,name in ipairs(callbacks) do cls[name]=parent[name] end
        classes[#classes+1]=cls;return cls
    end
    _G.object={is_class=true}
    for slot,name in ipairs(callbacks) do
        object[name]=function() end;object[slot]=object[name]
    end
    for _,name in ipairs(bases) do _G[name]=Class(object) end
    local environment={}
    -- Explicitly model the engine's dispatch completion after synchronous capture.
    function environment:FinishLoad()
        for _,cls in ipairs(classes) do
            for slot,name in ipairs(callbacks) do cls[slot]=cls[name] end
        end
    end
    function environment:Restore()
        for _,name in ipairs(globals) do rawset(_G,name,saved[name]) end
    end
    return environment
end
return M
