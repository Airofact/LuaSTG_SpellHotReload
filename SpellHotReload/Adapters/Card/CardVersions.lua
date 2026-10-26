-- Card-owned callback versions and private capture mappings. No Local ledger,
-- recursive provider selection, file revision, source execution or publication.
local Source=require("SpellHotReload.Source.FileAnalysis")
local Tree=require("SpellHotReload.Source.SyntaxTree")
local CardSyntax=require("SpellHotReload.Adapters.Card.CardSyntax")
local Compose=require("SpellHotReload.Source.Compose")
local Anchor=require("SpellHotReload.Load.Anchor")
local M={Kind="SpellHotReload.CardVersions",Version=2}
local CALLBACKS={"before","init","frame","render","beforedel","del","after"}
local allowed={};for _,name in ipairs(CALLBACKS) do allowed[name]=true end
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function dense(v)
    if not plain(v) then return false end
    local n,max=0,0
    for k in next,v do
        if type(k)~="number" or k<1 or k>=math.huge or k~=math.floor(k) then return false end
        n=n+1;max=math.max(max,k)
    end
    return n==max
end
local function copy(v) local out={};for k,x in next,v do out[k]=x end;return out end
local function same(a,b)
    if #a~=#b then return false end
    for i,x in ipairs(a) do if x~=b[i] then return false end end
    return true
end
local function fail(code,message,state,key)
    return nil,{phase="inject",code=code,message=message,file=plain(state) and state.file,unit_key=key}
end
local function key_of(class,slot) return "card:"..#class..":"..class..":"..slot end
local function signature(descriptor,name)
    return descriptor.callbacks[name] and descriptor.callback_signatures[name] or "default"
end
local function layout_copy(layout)
    local out={}
    for i,d in ipairs(layout) do
        out[i]={kind=d.kind,name=d.name,constructor=d.constructor,perform=d.perform,callbacks={init=d.callbacks.init}}
    end
    return out
end
local function same_layout(a,b)
    if not a or not b or #a~=#b then return false end
    for i,d in ipairs(a) do
        local n=b[i]
        if d.kind~=n.kind or d.constructor~=n.constructor or d.perform~=n.perform then return false end
    end
    return true
end
local function captures(record,entry,state,key)
    if record.body==nil then return {} end
    local plan,err=Compose.Plan(record.fn,entry)
    if not plan then return fail("stale",type(err)=="string" and err or "callback captures unavailable",state,key) end
    local names=copy(plan.names);table.sort(names)
    if not same(names,record.dependencies) then return fail("stale","published callback captures changed",state,key) end
    for _,join in ipairs(plan.joins) do
        if type(debug.upvalueid)=="function" then
            local a,b=debug.upvalueid(join.fn,join.index),debug.upvalueid(join.anchor,join.donor)
            if a==nil or b==nil or a~=b then return fail("stale","callback no longer shares Anchor",state,key) end
        end
    end
    return plan.joins
end
local function literal(source,descriptor,name,entry,defaults,providers,state,key)
    local body=descriptor.callbacks[name]
    if not body then return {body=nil,signature="default",fn=defaults[name],dependencies={},providers={},visible={}} end
    local node=descriptor.callback_syntax[name]
    local visible,err=Source.Visible(source,node)
    if not visible then return nil,err end
    local created,why=Compose.Create(body,nil,visible,{form="expression",syntax=node,name="CardVersions:"..key..":"..name})
    if not created then return fail("compile",type(why)=="string" and why or "callback construction failed",state,key) end
    local plan,perr=Compose.Plan(created,entry)
    if not plan then return fail("unsupported",type(perr)=="string" and perr or "callback binding unavailable",state,key) end
    local deps=copy(created.used);table.sort(deps)
    local refs={}
    for _,dep in ipairs(deps) do
        if not plain(providers[dep]) or source.bindings.by_name[dep]==nil then
            return fail("ownership","callback capture has no original provider",state,key)
        end
        refs[dep]=providers[dep]
    end
    return {body=body,signature=signature(descriptor,name),fn=created.fn,created=created,syntax=node,
        dependencies=deps,providers=refs,visible=visible,join_plan=plan}
end
local function stored(record,version,ref)
    return {body=record.body,signature=record.signature,fn=record.fn,
        dependencies=copy(record.dependencies),providers=copy(record.providers),visible=copy(record.visible),
        definition_version=version,unit_ref=ref}
end
local function project(state)
    local group={owner=state.owner,owner_id=state.owner_id,state=state,units={},records={},functions={},edges={}}
    for _,class in ipairs(state.classes) do group.units[#group.units+1]={unit_ref=state.class_refs[class],private_ref={class_key=class}} end
    for _,key in ipairs(state.order) do
        local unit=state.units[key]
        group.records[#group.records+1]={key=key,kind="card",definition=unit,definition_version=unit.definition_version,
            class_key=unit.class_key,slot=unit.slot}
        for _,name in ipairs(CALLBACKS) do
            local cb=unit.callbacks[name]
            group.records[#group.records+1]={key=key..":"..name,kind="callback",definition=cb,
                definition_version=cb.definition_version,card_key=key,callback=name,class_key=unit.class_key,slot=unit.slot}
            group.functions[#group.functions+1]=cb.fn
            for _,dep in ipairs(cb.dependencies) do group.edges[#group.edges+1]={consumer=unit.unit_ref,provider=cb.providers[dep]} end
        end
    end
    return group
end
-- provider(binding) is a genuine first-load owner's canonical Binding -> unit
-- mapping. Store references only, never that owner's records, versions or state.
function M.Seed(owner,entry,session,match,owners,ownership,classes,defaults,provider)
    if not plain(owner) or type(owner.Id)~="string" or not plain(entry) or not Source.Validate(entry.source)
        or not Anchor.Live(entry) or entry.reloadable~=true or not plain(entry.map) or not plain(match) or not dense(match.units) or not dense(owners)
        or not dense(ownership) or not plain(classes) or not plain(defaults) or type(provider)~="function"
        or type(session)~="string" or session=="" then return fail("ownership","genuine complete Card first load required",entry) end
    local state={kind=M.Kind,version=M.Version,owner=owner,owner_id=owner.Id,file=entry.file,
        entry=entry,anchor=entry.anchor,loaded_source=entry.loaded_source,session_id=session,
        classes={},class_refs={},layout={},order={},units={},providers={},defaults={}}
    local authority={cells={},raws={},forbidden={}}
    for _,name in ipairs(CALLBACKS) do
        if type(rawget(defaults,name))~="function" then return fail("ownership","seven saved defaults required",state) end
        state.defaults[name]=rawget(defaults,name);authority.forbidden[#authority.forbidden+1]=rawget(defaults,name)
    end
    for _,name in ipairs(entry.source.bindings.names) do
        local binding=entry.source.bindings.by_name[name]
        if not binding then return fail("ownership","unique original binding required",state) end
        local ref=provider(binding)
        if not plain(ref) or not plain(ref.owner) then return fail("ownership","original capture provider unavailable",state) end
        state.providers[name]=ref
    end
    local initial={classes=classes,ownership=ownership,match=match,source=entry.source,class_bindings={}}
    local identities,known={},{}
    local function identity(v) if type(v)=="table" and not known[v] then known[v]=true;identities[#identities+1]=v end end
    identity(classes)
    local class_owners={}
    for _,record in ipairs(ownership) do
        if not plain(record) or class_owners[record.class_key] or not plain(record.class) or not plain(record.list)
            or not dense(record.slots) or rawget(classes,record.class_key)~=record.class
            or rawget(record.class,"cards")~=record.list or not dense(record.list) or #record.list~=#record.slots then
            return fail("ownership","complete first-load class/list identity required",state)
        end
        class_owners[record.class_key]=record;identity(record.class);identity(record.list)
        for slot,card in ipairs(record.slots) do
            if not plain(card) or known[card] or rawget(record.list,slot)~=card then
                return fail("ownership","first-load slot identity reused or unavailable",state)
            end
            identity(card)
        end
    end
    local by_key={}
    for _,record in ipairs(owners) do
        if not plain(record) or type(record.class_key)~="string" or type(record.slot)~="number"
            or not plain(record.card) or not plain(record.callbacks) then return fail("ownership","complete combat owner required",state) end
        local key=key_of(record.class_key,record.slot)
        if by_key[key] then return fail("ownership","duplicate combat owner",state,key) end
        for name in next,record.callbacks do if not allowed[name] then return fail("unsupported","unknown first callback",state,key) end end
        by_key[key]=record
    end
    local consumed={}
    for i,class in ipairs(match.units) do
        local ctx=plain(class) and class.context
        if not plain(ctx) or type(ctx.class_key)~="string" or ctx.class_key=="" or not dense(ctx.layout) then
            return fail("ownership","complete Card class layout required",state)
        end
        local own=class_owners[ctx.class_key]
        if not own or state.layout[ctx.class_key] or #own.slots~=#ctx.layout then return fail("ownership","missing class owner",state) end
        state.classes[#state.classes+1]=ctx.class_key
        local ref={owner=owner,id=i};state.class_refs[ctx.class_key]=ref;state.layout[ctx.class_key]=layout_copy(ctx.layout)
        for slot,desc in ipairs(ctx.layout) do
            if desc.kind=="card" and desc.callbacks.init then
                local key=key_of(ctx.class_key,slot);local actual=by_key[key]
                if not actual or actual.card~=own.slots[slot] or rawget(actual.card,"is_combat")~=true then
                    return fail("ownership","missing captured combat card",state,key)
                end
                consumed[key]=true
                local unit={key=key,class_key=ctx.class_key,slot=slot,card=actual.card,unit_ref=ref,definition_version=1,callbacks={}}
                state.order[#state.order+1]=key;state.units[key]=unit
                for _,name in ipairs(CALLBACKS) do
                    local fn=rawget(actual.callbacks,name)
                    if type(fn)~="function" or rawget(actual.card,name)~=fn then return fail("stale","genuine first callback identity required",state,key) end
                    local candidate,err=literal(entry.source,desc,name,entry,state.defaults,state.providers,state,key)
                    if not candidate then return nil,err end
                    if candidate.body==nil and fn~=state.defaults[name] then return fail("stale","first default identity differs",state,key) end
                    candidate.fn=fn
                    local proof,why=captures(candidate,entry,state,key);if not proof then return nil,why end
                    unit.callbacks[name]=stored(candidate,1,ref)
                    authority.raws[#authority.raws+1]={unit_ref=ref,target=unit.card,key=name}
                end
            end
        end
    end
    for class in next,class_owners do if not state.layout[class] then return fail("ownership","unrecognized captured class",state) end end
    for key in next,by_key do if not consumed[key] then return fail("ownership","unrecognized combat owner",state,key) end end
    local Evidence=require("SpellHotReload.Adapters.Card.CardReconcile")
    for _,statement in ipairs(entry.source.analysis.statements) do
        local class=Evidence.ClassWriteKey(statement.syntax)
        if class then initial.class_bindings[class]=rawget(classes,class);identity(rawget(classes,class)) end
    end
    local group=project(state);group.initial=initial;group.identity_objects=identities;group.authority=authority
    return group
end
-- A genuinely Card-free first load contributes no invented registry/defaults.
function M.Empty(owner,entry,session,match)
    if not plain(owner) or type(owner.Id)~="string" or not plain(entry) or not Anchor.Live(entry)
        or not Source.Validate(entry.source) or not plain(match) or not dense(match.units) or #match.units~=0
        or type(session)~="string" or session=="" then return fail("ownership","genuine Card-free first load required",entry) end
    local state={kind=M.Kind,version=M.Version,owner=owner,owner_id=owner.Id,file=entry.file,
        entry=entry,anchor=entry.anchor,loaded_source=entry.loaded_source,session_id=session,
        classes={},class_refs={},layout={},order={},units={},providers={},defaults={}}
    local group=project(state)
    group.initial={source=entry.source,match=match,empty=true,ownership={},class_bindings={}}
    group.identity_objects={};group.authority={cells={},raws={},forbidden={}}
    return group
end
-- Match and source mapping are source-only evidence; real Locate owns locations.
-- A changed signature is recorded without constructing any candidate callback.
function M.Compare(group,initial,source,match,locations,rows)
    local state=plain(group) and group.state
    if not plain(state) or state.kind~=M.Kind or state.version~=M.Version or not plain(initial)
        or not Source.Validate(source) or not plain(match) or not dense(match.units)
        or not plain(locations) or not plain(locations.by_key) or not plain(rows) then
        return fail("ownership","actual Card group, complete source/location/rows required",state)
    end
    local view={kind=M.Kind..".View",version=M.Version,base=state,base_group=group,initial=initial,
        source=source,match=match,locations=locations,rows=rows,by_key={},pending_classes={},candidate_layout={},probes={}}
    local descriptors={}
    for _,class in ipairs(match.units) do
        view.candidate_layout[class.context.class_key]=class.context.layout
        for slot,desc in ipairs(class.context.layout) do descriptors[desc]=class.context.class_key..":"..slot end
    end
    for class,layout in next,state.layout do
        if not same_layout(layout,view.candidate_layout[class]) then view.pending_classes[class]=true end
    end
    for class in next,view.candidate_layout do if not state.layout[class] then view.pending_classes[class]=true end end
    local why
    view.before_facts,why=M.Facts(initial.source,initial.match,view.pending_classes)
    if not view.before_facts then return nil,why end
    view.after_facts,why=M.Facts(source,match,view.pending_classes)
    if not view.after_facts then return nil,why end
    view.wiring_changed=view.before_facts.wiring~=view.after_facts.wiring
    view.generated=next(state.layout)~=nil or next(view.candidate_layout)~=nil or view.before_facts.wiring~="" or view.after_facts.wiring~=""
    if view.generated then
        for _,name in ipairs({"_tmp_sc","_sc_table","_editor_class","boss","table"}) do
            if initial.source.bindings.by_name[name] or source.bindings.by_name[name] then
                view.blocked={code="unsupported",message="generated wiring name is shadowed: "..name}
            end
        end
    end
    for _,key in ipairs(state.order) do
        local old=state.units[key];local located=locations.by_key[key]
        if not plain(located) or located.key~=key then return fail("ownership","complete original Card locations required",state,key) end
        local descriptor=located.status=="located" and located.descriptor or nil
        if descriptor and descriptors[descriptor]~=old.class_key..":"..located.candidate_slot then
            return fail("ownership","located descriptor is outside original class discovery",state,key)
        end
        local item={key=key,previous=old,location=located,descriptor=descriptor,callbacks={},changed=false}
        if not descriptor then item.blocked={code="ambiguous",message=located.reason or "card has no proven source correspondence"} end
        for _,name in ipairs(CALLBACKS) do
            local previous=old.callbacks[name]
            -- Body equality alone cannot prove definition-point bindings stayed
            -- the same. Reuse full-source lexical facts; never rebuild source or
            -- construct an unselected callback. Resolve still rejects the drift.
            local binding_changed=false
            if descriptor and descriptor.callbacks[name] and previous.body~=nil then
                local visible,err=Source.Visible(source,descriptor.callback_syntax[name])
                if not visible then return nil,err end
                binding_changed=not same(visible,previous.visible)
            end
            local cb={previous=previous,changed=descriptor~=nil
                and (signature(descriptor,name)~=previous.signature or binding_changed)}
            item.callbacks[name]=cb;item.changed=item.changed or cb.changed
        end
        view.by_key[key]=item
    end
    return view
end
-- Exact saved default restoration requires source-only deletion evidence from
-- this owner/version and the same mapped descriptor; absence alone is insufficient.
local function deletion(view,item,name)
    local row=view.rows[item.key..":"..name]
    local previous=item.previous.callbacks[name]
    local tomb=plain(row) and row.tombstone;local into=plain(row) and row.candidate
    if name=="init" or not row or row.status~="deleted" or not plain(tomb) or tomb.owner~=view.base.owner
        or tomb.owner_id~=view.base.owner_id or not plain(row.previous) or row.previous.definition~=previous
        or row.previous.definition_version~=previous.definition_version or tomb.previous~=row.previous
        or tomb.definition_version~=previous.definition_version or not plain(into)
        or into.descriptor~=item.descriptor or into.slot~=item.location.candidate_slot or into.callback~=name then
        return fail("ambiguous","optional callback deletion lacks exact owner/version evidence",view.base,item.key)
    end
    return tomb
end
function M.Resolve(view,key)
    local item=plain(view) and view.by_key[key]
    if not item then return fail("ownership","unknown original Card selection",view and view.base,key) end
    if view.blocked then return nil,view.blocked end
    if item.blocked then return nil,item.blocked end
    if item.resolved then return item.resolved end
    local result={key=key,item=item,callbacks={},providers={},changed=item.changed,requires_file_check=false}
    local seen={}
    for _,name in ipairs(CALLBACKS) do
        local cb=item.callbacks[name];local record=cb.previous
        if cb.changed then
            local candidate,err=literal(view.source,item.descriptor,name,view.base.entry,view.base.defaults,view.base.providers,view.base,key)
            if not candidate then return nil,err end
            if record.body~=nil and candidate.body~=nil and not same(record.visible,candidate.visible) then
                return fail("unsupported","callback definition-point binding changed",view.base,key)
            end
            if record.body~=nil and candidate.body==nil then
                local tomb,why=deletion(view,item,name);if not tomb then return nil,why end
                candidate.deletion=tomb;result.requires_file_check=true
            end
            candidate.previous=record;record=candidate
            view.probes[key..":"..name]=candidate
        end
        result.callbacks[name]=record
        for _,dep in ipairs(record.dependencies) do
            local ref=record.providers[dep]
            if not seen[ref] then seen[ref]=true;result.providers[#result.providers+1]=ref end
        end
    end
    item.resolved=result;return result
end
-- Every actual callback/capture is checked even when blocked, absent or unselected.
function M.Reads(state)
    local reads,capture_reads={},{}
    for _,key in ipairs(state.order) do
        local unit=state.units[key]
        for _,name in ipairs(CALLBACKS) do
            local cb=unit.callbacks[name]
            if rawget(unit.card,name)~=cb.fn then return fail("stale","published raw callback was externally replaced",state,key) end
            reads[#reads+1]={owner=state.owner,unit_ref=unit.unit_ref,target=unit.card,key=name,value=cb.fn}
            local proof,err=captures(cb,state.entry,state,key);if not proof then return nil,err end
            for _,read in ipairs(proof) do
                local record=copy(read);record.owner=state.owner;record.unit_ref=unit.unit_ref
                capture_reads[#capture_reads+1]=record
            end
        end
    end
    return {read_set=reads,capture_reads=capture_reads}
end
-- Final keys are supplied by the owner AFTER root constraints. No provider
-- selection, Local preparation or recursive closure expansion takes place here.
function M.Prepare(view,keys,registry_reads)
    if not dense(keys) or not dense(registry_reads) then return fail("ownership","selected Card keys and pruned registry proof required",view.base) end
    for _,read in ipairs(registry_reads) do
        if not plain(read) or read.registry~=view.initial.classes or type(read.key)~="string"
            or not plain(read.value) or rawget(read.registry,read.key)~=read.value then
            return fail("stale","selected class binding changed before preparation",view.base)
        end
    end
    local reads,err=M.Reads(view.base);if not reads then return nil,err end
    local plan={view=view,keys={},selected={},publications={},joins={},raw_writes={},cell_writes={},
        read_set=reads.read_set,capture_reads=reads.capture_reads,registry_reads=copy(registry_reads),requires_file_check=false}
    for _,key in ipairs(keys) do
        if plan.selected[key] then return fail("ownership","duplicate Card selection",view.base,key) end
        local resolved,why=M.Resolve(view,key);if not resolved then return nil,why end
        plan.selected[key]=resolved;plan.keys[#plan.keys+1]=key
        plan.requires_file_check=plan.requires_file_check or resolved.requires_file_check
        for _,name in ipairs(CALLBACKS) do
            local cb=resolved.callbacks[name]
            if cb~=resolved.item.previous.callbacks[name] then
                local old=resolved.item.previous
                if cb.created then
                    local fresh,perr=Compose.Plan(cb.created,view.base.entry)
                    if not fresh then return fail("stale",type(perr)=="string" and perr or "prepared callback binding changed",view.base,key) end
                    for _,join in ipairs(fresh.joins) do
                        local record=copy(join);record.owner=view.base.owner;record.unit_ref=old.unit_ref
                        plan.joins[#plan.joins+1]=record
                    end
                end
                plan.raw_writes[#plan.raw_writes+1]={owner=view.base.owner,unit_ref=old.unit_ref,
                    target=old.card,key=name,before=cb.previous.fn,value=cb.fn}
                plan.publications[#plan.publications+1]={unit_key=key,key=name,target=old.card,before=cb.previous.fn,
                    value=cb.fn,callback=cb,deletion=cb.deletion}
            end
        end
    end
    return plan
end
function M.Next(plan)
    local state=plan.view.base
    if #plan.raw_writes==0 then return plan.view.base_group end
    local next_state=copy(state);next_state.units={}
    for _,key in ipairs(state.order) do
        local old=state.units[key];local unit=copy(old);unit.callbacks=copy(old.callbacks)
        next_state.units[key]=unit
    end
    local advanced={}
    for _,pub in ipairs(plan.publications) do
        local unit=next_state.units[pub.unit_key]
        unit.callbacks[pub.key]=stored(pub.callback,state.units[pub.unit_key].callbacks[pub.key].definition_version+1,unit.unit_ref)
        if not advanced[pub.unit_key] then unit.definition_version=unit.definition_version+1;advanced[pub.unit_key]=true end
    end
    return project(next_state)
end

local function safe_wiring(ast)
    local function scalar(n,numeric)
        if not n then return false end
        local unary=Tree.Match(n,"unary")
        if unary and unary.operator=="-" then
            local operand=Tree.Match(unary.operand,"literal")
            return operand~=nil and operand.category=="number"
        end
        local literal=Tree.Match(n,"literal")
        if not literal then return false end
        return literal.category=="number" or (not numeric and
            (literal.category=="string" or literal.category=="boolean" or literal.category=="nil"))
    end
    local function constructor(n)
        local kind,call=CardSyntax.Constructor(n)
        if kind~="card" and kind~="move" then return false end
        for argument,arg in ipairs(call.args) do
            local tuple=Tree.Match(arg,"table")
            if kind=="card" and argument==6 and tuple then
                if #tuple.fields~=3 then return false end
                for _,field in ipairs(tuple.fields) do
                    if not field.array or not scalar(field.value,true) then return false end
                end
            elseif not scalar(arg) then return false end
        end
        return true
    end
    local function item(n) return Tree.IsName(n,"_tmp_sc") or constructor(n) end
    local target,rhs=Tree.SingleAssignment(ast)
    if Tree.IsName(target,"_tmp_sc") then return constructor(rhs) end
    local member=Tree.Match(target,"member")
    if member and Tree.IsName(member.base,"_tmp_sc") and member.name=="perform" then
        local literal=Tree.Match(rhs,"literal")
        return literal~=nil and literal.category=="boolean"
    end
    local list=Tree.Match(rhs,"table")
    if CardSyntax.CardList(target) and list then
        for _,field in ipairs(list.fields) do if not field.array or not item(field.value) then return false end end
        return true
    end
    local call=Tree.Match(ast,"call_statement")
    if not call or Tree.Path(call.callee)~="table.insert" or #call.args~=2 then return false end
    if CardSyntax.CardList(call.args[1]) then return item(call.args[2]) end
    local record=Tree.Match(call.args[2],"table")
    if not Tree.IsName(call.args[1],"_sc_table") or not record or #record.fields~=5 then return false end
    local values={}
    for _,field in ipairs(record.fields) do
        if not field.array then return false end
        values[#values+1]=field.value
    end
    local length=Tree.Match(values[4],"unary")
    local final=Tree.Match(values[5],"literal")
    return Tree.String(values[1])~=nil and Tree.String(values[2])~=nil
        and Tree.IsName(values[3],"_tmp_sc")
        and length~=nil and length.operator=="#" and CardSyntax.CardList(length.operand)~=nil
        and final~=nil and final.category=="boolean"
end
-- Card facts cover only exact owned callback statements and safe generated
-- wiring. Local definition/declaration coverage stays with its original owner.
-- Whole classes are never masked. Function bodies are not top-level effects.
function M.Facts(source,match,pending_classes)
    local valid,err=Source.Validate(source)
    if not valid then return nil,err end
    if not plain(match) or not dense(match.units) or not plain(pending_classes or {}) then
        return fail("ownership","complete Card source match required")
    end
    local excluded,wiring,binding_reads,structures={},{},{},{}
    for _,unit in ipairs(match.units) do
        for _,desc in ipairs(unit.context.layout) do
            for name,node in next,desc.callback_syntax or {} do
                local site=source.sites[node]
                if not allowed[name] or not site or not site.statement then
                    return fail("ownership","callback syntax is not owned by this source")
                end
                local statement=source.analysis.statements[site.statement]
                local callback,fn=CardSyntax.Callback(statement.syntax)
                if callback~=name or fn~=node then return fail("ownership","callback is not a whole statement") end
                excluded[site.statement]=true
            end
        end
    end
    for index,statement in ipairs(source.analysis.statements) do
        local ast=statement.syntax;local wire=safe_wiring(ast)
        if wire then
            wiring[#wiring+1]=Tree.Signature(ast)
            excluded[index]=true
        end
        local call=Tree.Match(ast,"call_statement")
        structures[index]=wire or (call and Tree.IsName(call.callee,"_BOSS_ESCAPE")) or nil
        if not excluded[index] then
            local function reads(root)
                -- A delayed function is skipped unless an enclosing call may
                -- execute it immediately. Walk depth is relative to this root.
                Tree.Walk(root,function(n,parent,functions,calls)
                    if Tree.Is(n,"function") and calls==0 then return false end
                    if Tree.Is(n,"name") then
                        local name=Tree.Identifier(n)
                        if name=="_tmp_sc" or name=="_sc_table" then binding_reads[index]=true end
                        if name=="_editor_class" then
                            local indexed=Tree.Match(parent,"index")
                            local key=indexed and indexed.base==n and Tree.String(indexed.key)
                            if not key or pending_classes and pending_classes[key] then binding_reads[index]=true end
                        end
                    end
                end)
            end
            local values=Tree.Match(ast,"assignment") or Tree.Match(ast,"declaration")
            if values then
                for _,value in ipairs(values.values) do reads(value) end
            else reads(ast) end
        end
    end
    return {source=source,excluded=excluded,wiring=table.concat(wiring,"\n"),binding_reads=binding_reads,structures=structures}
end
function M.Bindings(root,classes,state,key,pending_classes,wiring_changed)
    if not root then return {} end
    local reads,refusal={}
    Tree.Walk(root,function(n,parent)
        if refusal then return false end
        if Tree.Is(n,"name") then
            local identifier=Tree.Identifier(n)
            if wiring_changed and (identifier=="_tmp_sc" or identifier=="_sc_table") then
                refusal="candidate generated-card binding depends on unpublished wiring: "..identifier;return false
            end
            if identifier=="_editor_class" then
                local indexed=Tree.Match(parent,"index")
                local name=indexed and indexed.base==n and Tree.String(indexed.key)
                if not name then refusal="dynamic class registry binding cannot be proved";return false end
                if not plain(classes) or not plain(rawget(classes,name)) then
                    refusal="candidate class binding is unavailable; registration remains pending";return false
                end
                if pending_classes[name] then
                    refusal="candidate class binding depends on unpublished layout: "..name;return false
                end
                reads[#reads+1]={registry=classes,key=name,value=rawget(classes,name)}
            end
        end
    end)
    if refusal then return fail("unsupported",refusal,state,key) end
    return reads
end
-- All owners' selected function AST facts carry exact root provenance from
-- Dependencies. Card checks business bindings; it never chooses Local units.
function M.Constraints(view,dependencies)
    if not plain(view) or not plain(dependencies) or not plain(dependencies.operation)
        or dependencies.operation.source~=view.source or dependencies.stable~=true
        or not dense(dependencies.safe_roots) or not dense(dependencies.source_facts) then
        return fail("ownership","stable same-source root facts required",view and view.base)
    end
    local roots={};local result={view=view,dependencies=dependencies,by_root={},blocked_roots={}}
    for _,root in ipairs(dependencies.safe_roots) do
        if not plain(root) or type(root.root_id)~="string" or roots[root.root_id] then
            return fail("ownership","unique safe roots required",view.base)
        end
        roots[root.root_id]=true;result.by_root[root.root_id]={reads={},facts={}}
    end
    for _,fact in ipairs(dependencies.source_facts) do
        if not plain(fact) or fact.source~=view.source or not Source.Owns(view.source,fact.node)
            or not Tree.Is(fact.node,"function")
            or not roots[fact.root_id] then return fail("ownership","foreign selected function fact",view.base) end
        local root=result.by_root[fact.root_id]
        root.facts[#root.facts+1]=fact
        if not root.blocked then
            local reads,err
            if view.blocked then err=view.blocked
            else reads,err=M.Bindings(fact.node,view.initial.classes,view.base,nil,view.pending_classes,view.wiring_changed) end
            if not reads then root.blocked=err
            else for _,read in ipairs(reads) do root.reads[#root.reads+1]=read end end
        end
    end
    for _,root in ipairs(dependencies.safe_roots) do
        local proof=result.by_root[root.root_id]
        if proof.blocked then result.blocked_roots[#result.blocked_roots+1]={root_id=root.root_id,reason=proof.blocked} end
    end
    return result
end
-- Called after ALL owner constraints have removed roots. Return only surviving
-- registry proofs; a rejected root cannot leave a stale read blocking another.
function M.RetainConstraints(view,constraints,dependencies)
    if not plain(constraints) or constraints.view~=view or not plain(dependencies)
        or dependencies.operation~=constraints.dependencies.operation or dependencies.stable~=true
        or not dense(dependencies.safe_roots) or not dense(dependencies.source_facts) then
        return fail("ownership","exact pruned Card constraints required",view.base)
    end
    local expected,reads,seen={},{},{}
    for _,root in ipairs(dependencies.safe_roots) do
        local proof=constraints.by_root[root.root_id]
        if not proof or proof.blocked or expected[root.root_id] then
            return fail("ownership","blocked or foreign root survived",view.base)
        end
        expected[root.root_id]={}
        for _,fact in ipairs(proof.facts) do expected[root.root_id][fact]=true end
        for _,read in ipairs(proof.reads) do
            seen[read.registry]=seen[read.registry] or {}
            local old=seen[read.registry][read.key]
            if old and old.value~=read.value then return fail("stale","registry observations disagree",view.base) end
            if not old then seen[read.registry][read.key]=read;reads[#reads+1]=read end
        end
    end
    for _,fact in ipairs(dependencies.source_facts) do
        if not plain(fact) or not expected[fact.root_id] or not expected[fact.root_id][fact] then
            return fail("ownership","pruned source fact changed",view.base)
        end
        expected[fact.root_id][fact]=nil
    end
    for _,facts in next,expected do
        if next(facts) then return fail("ownership","surviving root lost source facts",view.base) end
    end
    return reads
end
-- The Card adapter's two final Guards call this, including when it has no raw
-- writes. Registry identity is checked again after invalidation, never inferred
-- from an analysis/probe hit. Full layout/Current positioning belongs to Target.
function M.Guard(plan,classes)
    if not plain(plan) or not plain(plan.view) or not plan.view.initial.empty and classes~=plan.view.initial.classes
        or not dense(plan.registry_reads) then return fail("ownership","Card final read proof required",plan and plan.view and plan.view.base) end
    local reads,err=M.Reads(plan.view.base)
    if not reads then return nil,err end
    for _,read in ipairs(plan.registry_reads) do
        if not plain(read) or read.registry~=classes or rawget(classes,read.key)~=read.value then
            return fail("stale","candidate class registry identity changed",plan.view.base)
        end
    end
    return true
end
-- Scalar display derives from the ONE actual file snapshot. In particular,
-- helper-only publication leaves Card group/definition/callback identity intact.
function M.Observations(snapshot,group,key)
    if not plain(snapshot) or not dense(snapshot.owners) or not dense(snapshot.graph)
        or not plain(group) or not plain(group.state) or not group.state.units[key] then
        return fail("ownership","actual complete file snapshot and Card key required")
    end
    local found,refs,records,edges=false,{},{},{}
    for _,owner in ipairs(snapshot.owners) do
        if owner==group then found=true end
        for _,unit in ipairs(owner.units) do refs[unit.unit_ref]=true end
        for _,record in ipairs(owner.records) do
            local ref=record.definition.unit_ref
            if ref and record.kind=="function" then
                records[ref]=records[ref] or {};records[ref][#records[ref]+1]=record
            end
        end
    end
    if not found then return fail("stale","Card group is not the actual snapshot group",group.state,key) end
    for _,edge in ipairs(snapshot.graph) do
        if not refs[edge.consumer] or not refs[edge.provider] then return fail("ownership","foreign actual graph endpoint",group.state,key) end
        edges[edge.consumer]=edges[edge.consumer] or {};edges[edge.consumer][#edges[edge.consumer]+1]=edge.provider
    end
    local queue,seen,result,n={},{},{},1
    local function enqueue(ref)
        if not refs[ref] then return false end
        if not seen[ref] then seen[ref]=true;queue[#queue+1]=ref end
        return true
    end
    for _,name in ipairs(CALLBACKS) do
        local cb=group.state.units[key].callbacks[name]
        for _,dep in ipairs(cb.dependencies) do
            if not enqueue(cb.providers[dep]) then return fail("ownership","actual callback provider unavailable",group.state,key) end
        end
    end
    while n<=#queue do
        local ref=queue[n];n=n+1
        for _,record in ipairs(records[ref] or {}) do
            local name=record.name or record.key
            if result[name] and result[name]~=record.definition_version then
                return fail("ownership","ambiguous provider display name",group.state,key)
            end
            result[name]=record.definition_version
        end
        for _,provider in ipairs(edges[ref] or {}) do enqueue(provider) end
    end
    local names,out={},{}
    for name in next,result do names[#names+1]=name end;table.sort(names)
    for _,name in ipairs(names) do out[#out+1]={name=name,version=result[name]} end
    return out
end
-- Card supplies only its own exact callback coverage and retained wiring facts.
-- Local definitions/initializers are never hidden by this owner's class ranges.
function M.Coverage(view,plan)
    if not plain(view) or not plain(plan) or plan.view~=view or not plain(view.initial)
        or not plain(view.initial.source) or not plain(view.before_facts) or not plain(view.after_facts) then
        return fail("ownership","actual Card comparison and prepared domain scope required",view and view.base)
    end
    local function side(facts)
        return {scan=facts.source,claims={},excluded=copy(facts.excluded),
            structures=copy(facts.structures),binding_reads=copy(facts.binding_reads),wiring=facts.wiring}
    end
    local result={kind="SpellHotReload.FileCoverage",version=1,owner=view.base.owner,base_group=view.base_group,source=view.source,
        initial_source=view.initial.source,before=side(view.before_facts),after=side(view.after_facts),
        function_names={},pending={},scope=plan,requires_top_level=plan.requires_file_check==true}
    local function claim(side,node,name,key)
        if not node then return true end
        local site=side.scan.sites[node];local statement=site and side.scan.analysis.statements[site.statement]
        local callback,fn
        if statement then callback,fn=CardSyntax.Callback(statement.syntax) end
        if callback~=name or fn~=node or side.claims[site.statement] then
            return fail("ownership","Card coverage requires one whole owned callback statement",view.base,key)
        end
        side.claims[site.statement]=key;return true
    end
    local originals={}
    for _,class in ipairs(view.initial.match.units) do originals[class.context.class_key]=class.context.layout end
    for _,key in ipairs(view.base.order) do
        local old,item=view.base.units[key],view.by_key[key]
        local initial=originals[old.class_key] and originals[old.class_key][old.slot]
        if not item or not initial then return fail("ownership","complete original Card coverage unavailable",view.base,key) end
        local reason=view.blocked or item.blocked
        if reason then result.pending[#result.pending+1]={kind="identity",key=key,reason=reason.message} end
        for _,name in ipairs(CALLBACKS) do
            local member=key..":"..name
            local ok,err=claim(result.before,initial.callback_syntax[name],name,member)
            if not ok then return nil,err end
            local descriptor=item.descriptor
            local node=descriptor and descriptor.callback_syntax[name]
            if item.callbacks[name].changed then
                local point=descriptor.callback_points[name]
                local previous=initial.callback_points[name]
                result.pending[#result.pending+1]={kind="callback",key=member,reason="callback definition not published",
                    first=point and point.first,last=point and point.last,
                    previous_first=previous and previous.first,previous_last=previous and previous.last}
            end
            if node then
                ok,err=claim(result.after,node,name,member);if not ok then return nil,err end
            end
        end
    end
    for _,row in ipairs(view.locations.unowned) do
        local point=row.descriptor.callback_points.init
        result.pending[#result.pending+1]={kind="identity",key=row.source_key..":"..row.candidate_slot,
            reason=row.reason,first=point and point.first,last=point and point.last}
    end
    return result
end


-- Card-only scalar projection. A public class unit can contain several slots;
-- refine final impact using this slot's effective callback provider references.
function M.Describe(plan,snapshot,impact,dependencies)
    local view=plain(plan) and plan.view
    if not plain(view) or view.kind~=M.Kind..".View" or view.version~=M.Version
        or not plain(snapshot) or not dense(snapshot.owners) or not plain(impact)
        or not plain(impact.affected) or not plain(plan.selected) or not dense(plan.publications)
        or not plain(dependencies) or not dense(dependencies.blocked_roots) then
        return fail("unsupported","prepared Card owner and actual inspection snapshot required")
    end
    local found=false;for _,group in ipairs(snapshot.owners) do if group==view.base_group then found=true end end
    if not found then return fail("stale","Card description must use its actual snapshot group",view.base) end
    local direct={};for _,pub in ipairs(plan.publications) do direct[pub.unit_key]=true end
    local root_blocks={}
    for _,block in ipairs(dependencies.blocked_roots) do
        if view.base.units[block.root_id] then root_blocks[block.root_id]=block.reason end
    end
    local result={cards={},pending_sources={},tombstones={}}
    for _,key in ipairs(view.base.order) do
        local unit,item=view.base.units[key],view.by_key[key]
        local selected=plan.selected[key]
        local affected=direct[key]==true
        for _,name in ipairs(CALLBACKS) do
            local cb=selected and selected.callbacks[name] or unit.callbacks[name]
            for _,dep in ipairs(cb.dependencies) do
                if impact.affected[cb.providers[dep]] then affected=true end
            end
        end
        local observed,err=M.Observations(snapshot,view.base_group,key)
        if not observed then return nil,err end
        local blocked=view.blocked or item.blocked or root_blocks[key]
        local row={key=key,class_key=unit.class_key,slot=unit.slot,definition_version=unit.definition_version,
            action=item.location.status~="located" and item.location.status or blocked and "binding-blocked"
                or item.changed and "compile-publish" or affected and "shared-impact" or "keep-definition",
            selected=selected~=nil,pending=(item.changed or blocked~=nil) and selected==nil,
            affected=affected,observed=observed,callbacks={}}
        for _,name in ipairs(CALLBACKS) do
            row.callbacks[#row.callbacks+1]={name=name,definition_version=unit.callbacks[name].definition_version,
                changed=item.callbacks[name].changed==true}
        end
        result.cards[#result.cards+1]=row
        if item.location.status=="source-absent" then
            result.tombstones[#result.tombstones+1]={key=key,definition_version=unit.definition_version,
                action="restart-required",reason="class absent from candidate; live owner retained"}
        end
    end
    for _,item in ipairs(view.locations.unowned) do
        result.pending_sources[#result.pending_sources+1]={source_key=item.source_key,
            candidate_slot=item.candidate_slot,action="restart-required",reason=item.reason}
    end
    return result
end

return M
