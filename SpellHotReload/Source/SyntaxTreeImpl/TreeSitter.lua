-- One query snapshot owns the native tree and its additional facts.
-- Nodes are canonical TSNode cdata, never per-node Lua wrappers.
local Native=require('SpellHotReload.Source.Native')
local M,Snapshot={},{}
local DLL_PATH='.\\plugin\\SpellHotReload\\native\\dims_tree_sitter_lua.dll'
local roles={chunk=true,block=true,name=true,binding=true,literal=true,vararg=true,
 member=true,index=true,call=true,paren=true,['function']=true,unary=true,binary=true,
 ['table']=true,field=true,['local']=true,local_function=true,assign=true,
 function_statement=true,call_statement=true,['return']=true,['break']=true,
 ['do']=true,['while']=true,['repeat']=true,for_numeric=true,for_generic=true,['if']=true}
local patterns={declaration=true,assignment=true,definition=true,member=true,index=true,
 call=true,call_statement=true,literal=true,unary=true,['table']=true,['function']=true,['return']=true}
local native_roles={chunk='chunk',block='block',identifier='name',['nil']='literal',['true']='literal',['false']='literal',
 number='literal',string='literal',vararg_expression='vararg',dot_index_expression='member',
 method_index_expression='member',bracket_index_expression='index',function_call='call',
 parenthesized_expression='paren',function_definition='function',unary_expression='unary',
 binary_expression='binary',table_constructor='table',field='field',variable_declaration='local',
 assignment_statement='assign',return_statement='return',break_statement='break',do_statement='do',
 while_statement='while',repeat_statement='repeat',if_statement='if'}
local function check(value,why) if not value then error('syntax: '..why,0) end;return value end
local function append(a,b) for _,v in ipairs(b) do a[#a+1]=v end;return a end
local function add(a,b) if b then a[#a+1]=b end;return a end
local function decode(raw)
 if raw:sub(1,1)=='[' then
  local open=assert(raw:find('[',2,true));local value=raw:sub(open+1,#raw-open)
  value=value:gsub('\r\n','\n'):gsub('\n\r','\n'):gsub('\r','\n')
  return value:sub(1,1)=='\n' and value:sub(2) or value
 end
 local escapes={a='\a',b='\b',f='\f',n='\n',r='\r',t='\t',v='\v'}
 local out,i={},2
 while i<#raw do
  local c=raw:sub(i,i)
  if c~='\\' then out[#out+1]=c;i=i+1
  else
   i=i+1;c=raw:sub(i,i)
   if c:match('%d') then
    local digits=raw:sub(i):match('^%d%d?%d?');local value=tonumber(digits)
    check(value<=255,'string escape out of range');out[#out+1]=string.char(value);i=i+#digits
   elseif c=='\r' or c=='\n' then
    out[#out+1]='\n';i=i+1;local nextc=raw:sub(i,i)
    if nextc~=c and (nextc=='\r' or nextc=='\n') then i=i+1 end
   else
    check(escapes[c] or c=='\\' or c=="'" or c=='"','unsupported string escape')
    out[#out+1]=escapes[c] or c;i=i+1
   end
  end
 end
 return table.concat(out)
end
local function numeral(value)
 if value:match('^0[xX]') then return value:match('^0[xX]%x+$')~=nil end
 local base=value:match('^(.-)[eE][+-]?%d+$') or value
 return base:match('^%d+%.?%d*$')~=nil or base:match('^%.%d+$')~=nil
end
function M.IsSnapshot(value) return type(value)=='table' and getmetatable(value)==Snapshot end
function M.Parse(source,previous)
 if type(source)~='string' or source:find('\0',1,true) or source:sub(1,1)=='\27' then return nil,'text Lua source required','unsupported' end
 local compiler=rawget(_G,'loadstring') or rawget(_G,'load')
 local get=rawget(_G,'getfenv');local env=type(get)=='function' and get(0) or _G
 if type(compiler)~='function' then return nil,'Lua compiler unavailable','capability' end
 local compiled,chunk,why=pcall(compiler,source,'@FileAnalysis:syntax')
 if not compiled or type(chunk)~='function' then return nil,type(why)=='string' and why or (not compiled and type(chunk)=='string' and chunk) or 'source compilation failed','compile' end
 chunk=nil -- Compile the whole input once. Never execute it or recheck Lua control flow.
 local revision,session,fresh
 local ok,result=pcall(function()
  if previous then check(M.IsSnapshot(previous),'previous snapshot required');session=previous.revision.session
  else session=Native.Open(DLL_PATH);fresh=true end
  revision=session:Parse(source,previous and previous.revision)
  local s=setmetatable({revision=revision,source=source,
   syntax_check={compiler=compiler,runtime_key=env,environment_api=get}},Snapshot)
  local buckets,facts,by_node={},{},{}
  local expected_root
  local function entry(node) return check(by_node[node] and not revision.closed and by_node[node],'foreign or unknown native node') end
  local function record(node)
   check(revision:Owns(node),'foreign native node')
   local hash=Native.Hash(node);local bucket=buckets[hash]
   for _,e in ipairs(bucket or {}) do if Native.Equal(e.node,node) then return e end end
   local info=revision:Info(node)
   check(not info.invalid and info.a>=0 and info.b>=info.a and info.b<=#source,'invalid native range or ERROR/MISSING')
   local e={node=node,info=info};bucket=bucket or {};buckets[hash]=bucket;bucket[#bucket+1]=e
   facts[e]=true;by_node[node]=e;return e
  end
  local function parts(node)
   local e=entry(node)
   if not e.parts then
    local values,named,fields={},{},{}
    for i=0,e.info.count-1 do
     local child=record(revision:Child(e.node,i));local key=revision:Field(e.node,i)
     values[#values+1]=child.node
     if child.info.named and not child.info.extra then named[#named+1]=child.node end
     if key~='' then local list=fields[key] or {};fields[key]=list;list[#list+1]=child.node end
    end
    e.parts,e.named,e.fields=values,named,fields;facts[values],facts[named],facts[fields]=true,true,true
   end
   return e
  end
  local function named(node) return node and parts(node).named or {} end
  local function fields(node,key) return parts(node).fields[key] or {} end
  local function get(node,key,required)
   local values=fields(node,key);check(#values<=1,'ambiguous field '..key)
   if required then check(values[1],'missing field '..key) end
   return values[1]
  end
  local function one(node,kind)
   local found
   for _,child in ipairs(named(node)) do
    if entry(child).info.kind==kind then check(not found,'duplicate '..kind);found=child end
   end
   return check(found,'missing '..kind)
  end
  local function kind(node)
   local e=entry(node)
   if not e.kind then
    local k=native_roles[e.info.kind]
    if e.info.kind=='function_declaration' then k=source:sub(e.info.a+1,e.info.a+5)=='local' and 'local_function' or 'function_statement'
    elseif e.info.kind=='for_statement' then k=entry(get(node,'clause',true)).info.kind=='for_numeric_clause' and 'for_numeric' or 'for_generic' end
    e.kind=check(k,'unsupported native node '..e.info.kind)
   end
   return e.binding and 'binding' or e.kind
  end
  local function node(value,binding,opaque_literals)
   if not value then return nil end
   local e=entry(value)
   if binding then check(e.info.kind=='identifier','identifier binding required');e.binding=true end
   local k=kind(e.node)
   if k=='literal' and not opaque_literals and not e.literal_ready then
    local raw=source:sub(e.info.a+1,e.info.b)
    if e.info.kind=='string' then e.literal=decode(raw)
    elseif e.info.kind=='number' then check(numeral(raw),'unsupported numeral spelling') end
    e.literal_ready=true
   end
   return e.node
  end
  -- Reference facts share the same entity/role constructor; they do not need
  -- literal values. Ordinary queries still materialize and validate literals.
  local function reference(value,binding) return node(value,binding,true) end
  local function refs(value,binding,resolve)
   resolve=resolve or node
   local out={};for _,child in ipairs(named(value)) do out[#out+1]=resolve(child,binding) end;return out
  end
  local function text(value)
   local e=entry(value)
   if not e.text then e.text=source:sub(e.info.a+1,e.info.b) end
   return e.text
  end
  local function is_function(value)
   local k=kind(value);return k=='function' or k=='local_function' or k=='function_statement'
  end
  local function declarations(value,resolve)
   resolve=resolve or node
   if kind(value)=='local_function' then return {names={resolve(get(value,'name',true),true)},values={value},self_visible=true} end
   local p=named(value);check(#p==1,'local declaration shape')
   local variables,values
   if entry(p[1]).info.kind=='assignment_statement' then variables,values=one(p[1],'variable_list'),one(p[1],'expression_list')
   else variables=p[1];check(entry(variables).info.kind=='variable_list','local variable list') end
   return {names=refs(variables,true,resolve),values=refs(values,nil,resolve),self_visible=false}
  end
  local function function_parts(value,resolve)
   resolve=resolve or node
   local parameters=get(value,'parameters',true);local params,vararg={},false
   for _,p in ipairs(named(parameters)) do
    if entry(p).info.kind=='vararg_expression' then vararg=true else params[#params+1]=resolve(p,true) end
   end
   return {params=params,vararg=vararg,body=resolve(get(value,'body'))},parameters
  end
  function s.IsNode(value) return by_node[value]~=nil and not revision.closed end
  function s.SameNode(a,b) return s.IsNode(a) and s.IsNode(b) and Native.Equal(a,b) or false end
  function s.Owns(value) return revision:Owns(value) end
  function s.ContainsFact(value) return value==s or value==s.syntax_check or value==revision or facts[value]==true or revision:Owns(value) end
  function s.MatchesInput(value) return s.revision==revision and s.source==source and s.root==expected_root and not revision.closed and source==value end
  function s.Range(value) local e=entry(value);return e.info.a+1,e.info.b end
  function s.Text(value) return text(value) end
  function s.Display(value) return text(value) end
  -- Lua strings provide hashing/interning plus exact equality on collision.
  -- Formatting inside the span participates; this is content identity, not a unit id.
  function s.Signature(value)
   local e=entry(value)
   if e.signature==nil then
    local last=e.info.b
    if e.statement and source:sub(last,last)==';' then last=last-1 end
    e.signature=source:sub(e.info.a+1,last)
   end
   return e.signature
  end
  function s.Is(value,role)
   check(roles[role],'unknown role '..tostring(role));if value==nil then return false end
   if role=='function' then return is_function(value) end
   if role=='call_statement' then return kind(value)=='call' and entry(value).statement==true end
   return kind(value)==role
  end
  function s.Identifier(value)
   if value~=nil then local k=kind(value);if k=='name' or k=='binding' then return text(value),k=='binding' end end
  end
  function s.IsName(value,name) return s.Is(value,'name') and s.Identifier(value)==name or false end
  function s.Statements(value)
   if value==nil then return {} end -- No synthetic node for an absent empty block.
   local k=kind(value);check(k=='block' or k=='chunk','statement sequence required')
   local out={}
   for _,child in ipairs(named(value)) do
    if entry(child).info.kind~='empty_statement' then entry(child).statement=true;out[#out+1]=node(child) end
   end
   return out
  end
  local function match(value,pattern,resolve)
   check(patterns[pattern],'unknown pattern '..tostring(pattern));if value==nil then return nil end
   local e=entry(value);local k=kind(value)
   if pattern=='declaration' then if k=='local' or k=='local_function' then return declarations(value,resolve) end
   elseif pattern=='assignment' then if k=='assign' then return {targets=refs(one(value,'variable_list'),nil,resolve),values=refs(one(value,'expression_list'),nil,resolve)} end
   elseif pattern=='definition' then
    local target,fn,method,self_visible,form
    if k=='local_function' then target,fn,self_visible,form=resolve(get(value,'name',true),true),value,true,'local-function'
    elseif k=='function_statement' then target,fn,form=resolve(get(value,'name',true)),value,'function-statement';method=entry(target).info.kind=='method_index_expression'
    elseif k=='local' then local d=declarations(value,resolve);if #d.names==1 and #d.values==1 and is_function(d.values[1]) then target,fn,form=d.names[1],d.values[1],'local-initializer' end
    elseif k=='assign' then local a=match(value,'assignment',resolve);if #a.targets==1 and #a.values==1 and is_function(a.values[1]) then target,fn,form=a.targets[1],a.values[1],'assignment' end end
    if fn then return {target=target,fn=fn,method=method==true,self_visible=self_visible==true,form=form} end
   elseif pattern=='member' then if k=='member' then
    local method=e.info.kind=='method_index_expression'
    return {base=resolve(get(value,'table',true)),name=text(get(value,method and 'method' or 'field',true)),separator=method and ':' or '.'}
   end
   elseif pattern=='index' then if k=='index' then return {base=resolve(get(value,'table',true)),key=resolve(get(value,'field',true))} end
   elseif pattern=='call' or pattern=='call_statement' then
    if k=='call' and (pattern=='call' or e.statement) then local callee=resolve(get(value,'name',true));return {node=value,callee=callee,args=refs(get(value,'arguments',true),nil,resolve),method=entry(callee).info.kind=='method_index_expression'} end
   elseif pattern=='literal' then if k=='literal' then
    local raw=text(value);local category=e.info.kind
    if category=='true' or category=='false' then category='boolean' end
    if category=='string' and e.literal==nil then e.literal=decode(raw) end
    return {category=category,value=e.literal,raw=raw}
   end
   elseif pattern=='unary' then if k=='unary' then
    local operator
    for _,child in ipairs(parts(value).parts) do local i=entry(child).info
     if not i.named and not i.extra then operator=i.kind;break end
    end
    check(operator=='not' or operator=='#' or operator=='-','unsupported unary operator')
    return {operator=operator,operand=resolve(get(value,'operand',true))}
   end
   elseif pattern=='table' then if k=='table' then
    local out={}
    for _,f in ipairs(named(value)) do
     check(entry(f).info.kind=='field','table field required');resolve(f)
     local key,label;local native_key=get(f,'name')
     if native_key then if text(f):sub(1,1)=='[' then key=resolve(native_key) else label=text(native_key) end end
     out[#out+1]={node=f,key=key,name=label,array=key==nil and label==nil,value=resolve(get(f,'value',true))}
    end
    return {fields=out}
   end
   elseif pattern=='function' then if is_function(value) then return (function_parts(value,resolve)) end
   elseif pattern=='return' then if k=='return' then local p=named(value);check(#p<=1,'return shape');return {values=refs(p[1],nil,resolve)} end end
  end
  function s.Match(value,pattern) return match(value,pattern,node) end
  function s.String(value) local v=s.Match(value,'literal');if v and v.category=='string' then return v.value end end
  local function children(value,resolve)
   local k=kind(value)
   if k=='chunk' or k=='block' then return s.Statements(value)
   elseif is_function(value) then
    local f=function_parts(value,resolve);local out={}
    if k=='local_function' then add(out,resolve(get(value,'name',true),true))
    elseif k=='function_statement' then add(out,resolve(get(value,'name',true))) end
    append(out,f.params);return add(out,f.body)
   elseif k=='local' then local d=declarations(value,resolve);return append(d.names,d.values)
   elseif k=='assign' then local a=match(value,'assignment',resolve);return append(a.targets,a.values)
   elseif k=='member' then return {match(value,'member',resolve).base}
   elseif k=='index' then local v=match(value,'index',resolve);return {v.base,v.key}
   elseif k=='call' then local v=match(value,'call',resolve);return append({v.callee},v.args)
   elseif k=='paren' then return refs(value,nil,resolve)
   elseif k=='unary' then return {match(value,'unary',resolve).operand}
   elseif k=='binary' then return {resolve(get(value,'left',true)),resolve(get(value,'right',true))}
   elseif k=='table' then local out={};for _,f in ipairs(match(value,'table',resolve).fields) do add(out,f.key);add(out,f.value) end;return out
   elseif k=='return' then return match(value,'return',resolve).values
   elseif k=='do' then return add({},resolve(get(value,'body')))
   elseif k=='while' then return add({resolve(get(value,'condition',true))},resolve(get(value,'body')))
   elseif k=='repeat' then local out=add({},resolve(get(value,'body')));return add(out,resolve(get(value,'condition',true)))
   elseif k=='for_numeric' or k=='for_generic' then
    local c=get(value,'clause',true);local out
    if k=='for_numeric' then out={resolve(get(c,'name',true),true),resolve(get(c,'start',true)),resolve(get(c,'end',true))};add(out,resolve(get(c,'step')))
    else out=append(refs(one(c,'variable_list'),true,resolve),refs(one(c,'expression_list'),nil,resolve)) end
    return add(out,resolve(get(value,'body')))
   elseif k=='if' then
    local out={resolve(get(value,'condition',true))};add(out,resolve(get(value,'consequence')))
    for _,alternative in ipairs(fields(value,'alternative')) do
     if entry(alternative).info.kind=='elseif_statement' then add(out,resolve(get(alternative,'condition',true)));add(out,resolve(get(alternative,'consequence')))
     else check(entry(alternative).info.kind=='else_statement','if alternative');add(out,resolve(get(alternative,'body'))) end
    end
    return out
   end
   return {}
  end
  local function walk_nodes(value,visit,resolve)
   if value==nil then return end;check(type(visit)=='function','visitor required')
   local function walk(current,parent,functions,calls)
    if is_function(current) then functions=functions+1 end
    if kind(current)=='call' then calls=calls+1 end
    if visit(current,parent,functions,calls)==false then return end
    for _,child in ipairs(children(current,resolve)) do walk(child,current,functions,calls) end
   end
   walk(value,nil,0,0)
  end
  function s.Walk(value,visit) return walk_nodes(value,visit,node) end
  -- Names are structural references, including delayed function bodies. The
  -- shared traversal excludes bindings/field labels without decoding literals.
  function s.Names(value)
   local out={};walk_nodes(value,function(n) if s.Is(n,'name') then out[#out+1]=n end end,reference);return out
  end
  function s.Path(value)
   if s.Is(value,'name') then return s.Identifier(value) end
   local m=s.Match(value,'member');if m then local p=s.Path(m.base);if p then return p..m.separator..m.name end end
  end
  function s.Root(value)
   if s.Is(value,'name') then return s.Identifier(value) end
   local m=s.Match(value,'member') or s.Match(value,'index');if m then return s.Root(m.base) end
  end
  function s.SingleAssignment(value)
   local a=s.Match(value,'assignment');if a and #a.targets==1 and #a.values==1 then return a.targets[1],a.values[1] end
  end
  function s.FunctionRange(value)
   check(is_function(value),'function required');local first,last
   for _,child in ipairs(parts(value).parts) do
    local info=entry(child).info
    if info.kind=='function' then first=info.a+1 elseif info.kind=='end' then last=info.b end
   end
   return check(first,'function keyword missing'),check(last,'function end missing')
  end
  function s.FunctionSource(value,method)
   check(is_function(value),'function required');local f,parameters=function_parts(value)
   local open=entry(parameters).info.a+1;local _,last=s.FunctionRange(value);local tail=source:sub(open+1,last)
   if method then tail='self'..((#f.params>0 or f.vararg) and ',' or '')..tail end
   return 'function('..tail
  end
  s.FunctionSignature=s.FunctionSource
  local line_starts
  function s.Line(value)
   if not line_starts then
    line_starts={1};local at=1
    while true do local a=source:find('[\r\n]',at);if not a then break end
     at=a+1;local c,n=source:sub(a,a),source:sub(at,at)
     if c~=n and (n=='\r' or n=='\n') then at=at+1 end
     line_starts[#line_starts+1]=at
    end
   end
   local first=s.Range(value);local low,high=1,#line_starts
   while low<high do local mid=math.floor((low+high+1)/2);if line_starts[mid]<=first then low=mid else high=mid-1 end end
   return low
  end
  function s.RetainParser() return Native.Retain(session) end
  -- Only the builder may discard an analysis that has not been returned to a reader.
  function s.Discard()
   revision:Close();if fresh then session:Close() end
  end
  s.root=record(revision:Root()).node;expected_root=s.root
  check(entry(s.root).info.kind=='chunk','whole native tree required');kind(s.root)
  return s
 end)
 if not ok then if revision then revision:Close() end;if fresh and session then session:Close() end;return nil,tostring(result),'unsupported' end
 return result
end
return M
