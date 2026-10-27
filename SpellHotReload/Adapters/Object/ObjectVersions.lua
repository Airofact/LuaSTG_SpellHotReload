-- Object owns class identity, callback versions, dispatch slots and inheritance.
-- No mutation here. FileCommit installs the paired writes in one common journal.
local D=require('SpellHotReload.Adapters.Object.ObjectDefinitions')
local Observe=require('SpellHotReload.Adapters.Object.ObjectLoad')
local Compose=require('SpellHotReload.Source.Compose')
local Anchor=require('SpellHotReload.Load.Anchor')
local Source=require('SpellHotReload.Source.FileAnalysis')
local Local=require('SpellHotReload.Adapters.Local.Local')
local M={Kind='SpellHotReload.ObjectVersions',Version=1}
local plain=D.Plain
local function copy(v) local out={};for k,x in next,v do out[k]=x end;return out end
local function fail(message,state,key)
    return nil,{phase='object',code='unsupported',message=message,file=state and state.file,unit_key=key}
end
local function same(a,b)
    if #a~=#b then return false end
    for i,v in ipairs(a) do if b[i]~=v then return false end end
    return true
end
local function line(source,node)
    local Tree=source.analysis.syntax
    local first=Tree.Line(node)
    local text=Tree.Text(node):gsub('\r\n','\n'):gsub('\n\r','\n')
    local _,count=text:gsub('[\r\n]','')
    return first,first+count
end
local function shared(fn,entry,dependencies)
    local proof,err=Compose.Plan(fn,entry)
    if not proof then return nil,err end
    local names=copy(proof.names);table.sort(names)
    if not same(names,dependencies) then return nil,'published method captures changed' end
    for _,j in ipairs(proof.joins) do
        if type(debug.upvalueid)~='function'
            or debug.upvalueid(j.fn,j.index)~=debug.upvalueid(j.anchor,j.donor) then
            return nil,'published method no longer shares original Anchor'
        end
    end
    return proof.joins
end
local function prepared(source,definition,entry,providers)
    local created,err=Compose.Create(definition.body,nil,definition.visible,
        {form='expression',tree=source.analysis.syntax,syntax=definition.syntax,name='Object callback'})
    if not created then return nil,err end
    local proof,why=Compose.Plan(created,entry);if not proof then return nil,why end
    local dependencies=copy(created.used);table.sort(dependencies)
    for _,name in ipairs(dependencies) do if not providers[name] then return nil,'original Local provider missing' end end
    return {fn=created.fn,created=created,signature=definition.signature,
        dependencies=dependencies,visible=copy(definition.visible),definition=definition}
end
local function stored(record,version)
    return {fn=record.fn,signature=record.signature,dependencies=copy(record.dependencies),
        visible=copy(record.visible),definition_version=version}
end
local function project(state)
    local g={owner=state.owner,owner_id=state.owner.Id,state=state,units={},records={},functions={},edges={}}
    for _,key in ipairs(state.order) do
        local u=state.by_key[key]
        g.units[#g.units+1]={unit_ref=u.unit_ref,private_ref={key=key}}
        g.records[#g.records+1]={key='object:'..key,kind='object',class_key=key,definition=u,definition_version=u.definition_version}
        for _,name in ipairs(D.Callbacks) do
            local cb=u.callbacks[name]
            g.functions[#g.functions+1]=cb.fn
            if cb.owned then
                g.records[#g.records+1]={key='object:'..#key..':'..key..':'..name,kind='callback',
                    class_key=key,definition=cb,definition_version=cb.definition_version}
                for _,dep in ipairs(cb.dependencies) do
                    g.edges[#g.edges+1]={consumer=u.unit_ref,provider=state.providers[dep]}
                end
            end
        end
    end
    return g
end
function M.Seed(owner,entry,session,local_group,p)
    if not Anchor.Live(entry) or entry.reloadable~=true or type(session)~='string' or session=='' then
        return fail('genuine reloadable first load required',entry)
    end
    local observation=entry.object_load
    local state={kind=M.Kind,version=M.Version,owner=owner,file=entry.file,session_id=session,
        entry=entry,order={},by_key={},providers={}}
    local authority={cells={},raws={},forbidden={}}
    local initial={projection=p,registry=observation and observation.registry or rawget(_G,'_editor_class'),bindings={}}
    local identities,known={},{}
    local function identity(v)
        if type(v)=='table' and not known[v] then known[v]=true;identities[#identities+1]=v end
    end
    for _,name in ipairs(Source.DeclaredNames(entry.source)) do
        local declaration=Source.Declaration(entry.source,name)
        local ref=declaration and Local.CapturedProvider(local_group,declaration)
        if not ref then return fail('original Local provider missing',state) end
        state.providers[name]=ref
    end
    local eligible={}
    for _,key in ipairs(p.order) do if p.by_key[key].supported and not p.by_key[key].reason then eligible[#eligible+1]=key end end
    if #eligible>0 then
        if not plain(observation) or observation.kind~=Observe.Kind or observation.version~=Observe.Version
            or not observation.intact or not plain(observation.registry) or not plain(observation.all_class) then
            return fail('normal Class construction observation unavailable; restart game',state)
        end
        state.registry,state.all_class=observation.registry,observation.all_class
        identity(state.registry);identity(state.all_class)
    end
    if plain(initial.registry) then
        identity(initial.registry)
        for _,key in ipairs(eligible) do
            local value=rawget(initial.registry,key);initial.bindings[key]=value;identity(value)
        end
    end
    local source_name=debug.getinfo(entry.anchor,'S').source
    for _,key in ipairs(eligible) do
        local d=p.by_key[key];local ctor=d.constructor
        local cls=rawget(state.registry,key);local base=observation.bases[ctor.base_name]
        if not plain(cls) or not plain(base) or rawget(base,'is_class')~=true
            or rawget(cls,'is_class')~=true or rawget(cls,'base')~=base
            or rawget(cls,'default_function')~=nil and rawget(cls,'default_function')~=0
            or rawget(cls,'.render')~=nil and rawget(cls,'.render')~=false then
            return fail('class/base identity or engine dispatch flags unsupported',state,key)
        end
        local count,found=0,nil
        local first,last=line(p.source,ctor.value)
        for _,call in ipairs(observation.calls) do
            if call.class==cls then count=count+1;found=call end
        end
        if count~=1 or found.base~=base or found.argc~=1 or found.arity~=1 or found.define~=nil
            or found.source~=source_name or not found.line or found.line<first or found.line>last then
            return fail('class does not correspond to exactly one observed source constructor',state,key)
        end
        local membership=0
        for _,value in next,state.all_class do if value==cls then membership=membership+1 end end
        if membership~=1 then return fail('class registration is absent or repeated',state,key) end
        for other,value in next,state.registry do
            if other~=key and value==cls then return fail('class registry alias cannot prove unique ownership',state,key) end
        end
        identity(cls);identity(base)
        local ref={owner=owner,id=#state.order+1}
        local u={key=key,class=cls,base=base,base_name=ctor.base_name,unit_ref=ref,
            definition_version=1,callbacks={},descendants={},
            default_function=rawget(cls,'default_function'),render_flag=rawget(cls,'.render')}
        state.order[#state.order+1]=key;state.by_key[key]=u
        for slot,name in ipairs(D.Callbacks) do
            local fn=rawget(cls,name);local numeric=rawget(cls,slot)
            if type(fn)~='function' or numeric~=0 and numeric~=fn then return fail('initial named/dispatch shape unavailable',state,key) end
            local definition=d.methods[name] and d.methods[name][1]
            local record={fn=fn,owned=false}
            if definition then
                local info=debug.getinfo(fn,'S')
                if info.what~='Lua' or info.source~=source_name or info.linedefined~=line(p.source,definition.syntax) then
                    return fail('method was not defined at its observed first-load source site',state,key)
                end
                local candidate,err=prepared(p.source,definition,entry,state.providers)
                if not candidate then return fail(err,state,key) end
                candidate.fn=fn
                local proof,why=shared(fn,entry,candidate.dependencies)
                if not proof then return fail(why,state,key) end
                record=stored(candidate,1);record.owned=true
                authority.raws[#authority.raws+1]={unit_ref=ref,target=cls,key=name}
                authority.raws[#authority.raws+1]={unit_ref=ref,target=cls,key=slot}
            end
            u.callbacks[name]=record
        end
    end
    -- Remember known copied inheritance before later live metadata can erase it.
    for _,key in ipairs(state.order) do
        local u=state.by_key[key]
        for _,cls in next,state.all_class do
            local cursor,seen=cls,{}
            while plain(cursor) and cursor~=u.class and not seen[cursor] do
                seen[cursor]=true;cursor=rawget(cursor,'base')
            end
            if cls~=u.class and cursor==u.class then
                local base=rawget(cls,'base');identity(cls);identity(base)
                u.descendants[#u.descendants+1]={class=cls,base=base}
            end
        end
    end
    local group=project(state)
    group.initial,group.authority,group.identity_objects=initial,authority,identities
    return group
end
function M.Compare(group,initial,p)
    local state=group.state
    local view={base_group=group,base=state,initial=initial,projection=p,source=p.source,by_key={},pending_classes={}}
    for _,key in ipairs(initial.projection.order) do
        local a,b=initial.projection.by_key[key],p.by_key[key]
        if not b or #a.constructors~=#b.constructors or a.constructor and
            (not b.constructor or a.constructor.signature~=b.constructor.signature) then view.pending_classes[key]=true end
    end
    for _,key in ipairs(p.order) do if not initial.projection.by_key[key] then view.pending_classes[key]=true end end
    for _,key in ipairs(state.order) do
        local old=state.by_key[key]
        local d,err=D.Pair(initial.projection,p,key)
        local item={previous=old,descriptor=d,blocked=err,callbacks={}}
        view.by_key[key]=item
        for _,name in ipairs(D.Callbacks) do
            local before=old.callbacks[name]
            local defs=d and d.methods[name];local def=defs and #defs==1 and defs[1]
            local cb={previous=before,definition=def}
            if before.owned then
                cb.blocked=err or not def and 'callback deletion is not supported' or nil
                cb.changed=cb.blocked~=nil or def.signature~=before.signature
                if def and not same(before.visible,def.visible) then cb.blocked='method definition-point visibility changed' end
            elseif def then cb.blocked='callback addition is not supported';cb.changed=true end
            item.callbacks[name]=cb
        end
    end
    return view
end
function M.Reads(state)
    local result={read_set={},capture_reads={}}
    if not Anchor.Live(state.entry) then return fail('Object Anchor is no longer live',state) end
    if #state.order==0 then return result end
    if rawget(_G,'_editor_class')~=state.registry or rawget(_G,'all_class')~=state.all_class then
        return fail('class registry or registration table identity changed',state)
    end
    for _,key in ipairs(state.order) do
        local u=state.by_key[key]
        if rawget(state.registry,key)~=u.class or rawget(u.class,'base')~=u.base
            or rawget(_G,u.base_name)~=u.base or getmetatable(u.class)~=nil
            or rawget(u.class,'is_class')~=true or rawget(u.class,'default_function')~=u.default_function
            or rawget(u.class,'.render')~=u.render_flag then return fail('live Object class identity/base/flags changed',state,key) end
        local membership=0
        for _,child in ipairs(u.descendants) do
            if rawget(child.class,'base')~=child.base then return fail('known derived class provenance changed',state,key) end
        end
        for _,cls in next,state.all_class do if cls==u.class then membership=membership+1 end end
        if membership~=1 then return fail('live class registration changed',state,key) end
        for other,cls in next,state.registry do
            if other~=key and cls==u.class then return fail('live registry alias was introduced',state,key) end
        end
        for slot,name in ipairs(D.Callbacks) do
            local cb=u.callbacks[name]
            -- Expected final slot comes from genuine named evidence, not zero.
            -- This does not revise source history when InitAllClass runs later.
            if rawget(u.class,name)~=cb.fn or rawget(u.class,slot)~=cb.fn then
                return fail('class dispatch not finalized or published method/slot drifted',state,key)
            end
            if cb.owned then
                result.read_set[#result.read_set+1]={owner=state.owner,unit_ref=u.unit_ref,target=u.class,key=name,value=cb.fn}
                result.read_set[#result.read_set+1]={owner=state.owner,unit_ref=u.unit_ref,target=u.class,key=slot,value=cb.fn}
                local proof,err=shared(cb.fn,state.entry,cb.dependencies)
                if not proof then return fail(err,state,key) end
                for _,join in ipairs(proof) do
                    local r=copy(join);r.owner=state.owner;r.unit_ref=u.unit_ref
                    result.capture_reads[#result.capture_reads+1]=r
                end
            end
        end
    end
    return result
end
function M.Inheritance(state,key,name)
    local target=state.by_key[key].class
    local known={};for _,k in ipairs(state.order) do known[state.by_key[k].class]=state.by_key[k] end
    for _,cls in next,state.all_class do
        if plain(cls) and cls~=target then
            local seen={};local cursor=cls
            while plain(cursor) and cursor~=target do
                if seen[cursor] then return fail('inheritance cycle cannot be bounded',state,key) end
                seen[cursor]=true;cursor=rawget(cursor,'base')
            end
            if cursor==target then
                -- Source evidence, never equality of inherited function values.
                local own=known[cls]
                if not own or not own.callbacks[name].owned then
                    return fail('known derived class may retain an inherited copy of '..name,state,key)
                end
            end
        end
    end
    return true
end
function M.Resolve(view,key,name)
    local item=view.by_key[key];local cb=item and item.callbacks[name]
    if not cb or not cb.previous.owned or cb.blocked then return fail(cb and cb.blocked or 'original owned callback required',view.base,key) end
    if not cb.changed then return {callback=cb.previous,changed=false} end
    local ok,why=M.Inheritance(view.base,key,name);if not ok then return nil,why end
    if not cb.prepared then
        local candidate,err=prepared(view.source,cb.definition,view.base.entry,view.base.providers)
        if not candidate then return fail(err,view.base,key) end
        cb.prepared=candidate
    end
    return {callback=cb.prepared,changed=true,node=cb.definition.syntax}
end
function M.Next(view,publications)
    if #publications==0 then return view.base_group end
    local state=copy(view.base);state.by_key={}
    for _,key in ipairs(state.order) do
        local u=copy(view.base.by_key[key]);u.callbacks=copy(u.callbacks);state.by_key[key]=u
    end
    local advanced={}
    for _,p in ipairs(publications) do
        local u=state.by_key[p.key]
        u.callbacks[p.name]=stored(p.callback,u.callbacks[p.name].definition_version+1)
        u.callbacks[p.name].owned=true
        if not advanced[p.key] then u.definition_version=u.definition_version+1;advanced[p.key]=true end
    end
    return project(state)
end
M.Copy=copy
M.Fail=fail
return M
