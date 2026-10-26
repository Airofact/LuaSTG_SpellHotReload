-- Public syntax queries over immutable native snapshots from any file parser.
-- Private entries retain handles/ranges, never a projected kind/children AST.
local Native=require("SpellHotReload.Source.Native")
local DLL_PATH=".\\plugin\\SpellHotReload\\native\\dims_tree_sitter_lua.dll"
local roles={chunk=true,block=true,name=true,binding=true,literal=true,vararg=true,
 member=true,index=true,call=true,paren=true,['function']=true,unary=true,binary=true,
 ['table']=true,field=true,['local']=true,local_function=true,assign=true,
 function_statement=true,call_statement=true,['return']=true,['break']=true,
 ['do']=true,['while']=true,['repeat']=true,for_numeric=true,for_generic=true,['if']=true}
local patterns={declaration=true,assignment=true,definition=true,member=true,index=true,
 call=true,call_statement=true,literal=true,unary=true,['table']=true,['function']=true,['return']=true}
local keywords={}
for w in ('and break do else elseif end false for function if in local nil not or repeat return then true until while'):gmatch('%S+') do keywords[w]=true end
local binaries={['or']=1,['and']=2,['<']=3,['>']=3,['<=']=3,['>=']=3,['~=']=3,['==']=3,['..']=4,['+']=5,['-']=5,['*']=6,['/']=6,['%']=6,['^']=8}
local unaries={['not']=true,['-']=true,['#']=true}
local native_roles={identifier='name',['nil']='literal',['true']='literal',['false']='literal',
 number='literal',string='literal',vararg_expression='vararg',dot_index_expression='member',
 method_index_expression='member',bracket_index_expression='index',function_call='call',
 parenthesized_expression='paren',function_definition='function',unary_expression='unary',
 binary_expression='binary',table_constructor='table',field='field',variable_declaration='local',
 assignment_statement='assign',return_statement='return',break_statement='break',do_statement='do',
 while_statement='while',repeat_statement='repeat',if_statement='if'}
local function check(value,message) if not value then error('syntax: '..message,0) end;return value end
local function append(out,values) for _,v in ipairs(values) do out[#out+1]=v end;return out end
local T={}
local snapshots=setmetatable({},{__mode='k'})
local function owner(node)
 local s=type(node)=='table' and rawget(node,1)
 if not s or not snapshots[s] or not s.entries[node] or s.revision.closed then error('syntax: foreign or invalid node reference',3) end
 return s
end
function T.IsNode(node)
 local s=type(node)=='table' and rawget(node,1)
 return s~=nil and snapshots[s]==true and s.entries[node]~=nil and not s.revision.closed or false
end
function T.SameSnapshot(a,b) return T.IsNode(a) and T.IsNode(b) and rawget(a,1)==rawget(b,1) or false end
function T.MatchesInput(root,source,tokens)
 if not T.IsNode(root) then return false end
 local s=owner(root);return s.root==root and s.source==source and s.tokens==tokens
end
function T.Parse(source,tokens,previous)
 if type(source)~='string' or type(tokens)~='table' then return nil,'syntax: source/tokens required' end
 local revision,s,session,fresh_session
 local ok,result=pcall(function()
  local prior
  if previous then local p=owner(previous);check(p.root==previous,'previous root required');prior=p.revision end
  if prior then session=prior.session
  else session=Native.Open(DLL_PATH);fresh_session=true end
  revision=session:Parse(source,prior)
  s={revision=revision,source=source,tokens=tokens,entries={},handles={}}
  local starts,ends={},{}
  for i,token in ipairs(tokens) do
   check(type(token.pos)=='number' and token.pos%1==0 and token.pos>=1 and type(token.value)=='string' and #token.value>0
    and source:sub(token.pos,token.pos+#token.value-1)==token.value and (i==1 or token.pos>ends[i-1]),'token/source mismatch')
   starts[token.pos]=i;ends[i]=token.pos+#token.value-1
  end
  local function span(native)
   local info=revision:Info(native);local first=starts[info.a+1]
   check(first,'node starts outside token boundary: '..info.kind)
   local low,high=first,#tokens
   while low<high do local mid=math.floor((low+high+1)/2);if ends[mid]<=info.b then low=mid else high=mid-1 end end
   check(ends[low]<=info.b,'node cuts token: '..info.kind)
   return first,low,info
  end
  local function named(native)
   local out={};if not native then return out end
   for i=0,revision:Info(native).count-1 do
    local child=revision:Child(native,i);local info=revision:Info(child)
    if info.named and not info.extra then out[#out+1]=child end
   end
   return out
  end
  local function fields(native,name)
   local out={}
   for i=0,revision:Info(native).count-1 do
    if revision:Field(native,i)==name then out[#out+1]=revision:Child(native,i) end
   end
   return out
  end
  local function get(native,name,required)
   local values=fields(native,name);check(#values<=1,'ambiguous field '..name)
   if required then check(values[1],'missing field '..name) end
   return values[1]
  end
  local function one(native,kind)
   local found
   for _,child in ipairs(named(native)) do if revision:Info(child).kind==kind then check(not found,'duplicate '..kind);found=child end end
   return check(found,'missing '..kind)
  end
  local function marker(native,kind)
   local found
   for i=0,revision:Info(native).count-1 do
    local child=revision:Child(native,i);local info=revision:Info(child)
    if info.kind==kind and not info.extra then check(not found,'duplicate marker '..kind);found=child end
   end
   return span(check(found,'missing marker '..kind))
  end
  local function identifier(native)
   local first,last,info=span(native);local token=tokens[first]
   check(info.kind=='identifier' and first==last and token.kind=='word' and not keywords[token.value]
    and token.pos-1==info.a and ends[last]==info.b,'identifier spelling/boundary')
   return token.value
  end
  local ref,statement,block,match,children
  local function entry(node) return check(s.entries[node],'node belongs to another snapshot') end
  ref=function(native,role,first,last,content_last,block_native)
   local info=revision:Info(native)
   if not first then first,last=span(native) end
   if not role then
    role=native_roles[info.kind]
    if info.kind=='function_declaration' then role=tokens[first].value=='local' and 'local_function' or 'function_statement'
    elseif info.kind=='for_statement' then role=revision:Info(get(native,'clause',true)).kind=='for_numeric_clause' and 'for_numeric' or 'for_generic' end
    check(role,'unsupported native node '..info.kind)
   end
   local key=revision:Key(native)..'/'..role..':'..first..':'..last
   local node=s.handles[key]
   if not node then
    node={s};s.handles[key]=node
    s.entries[node]={native=native,kind=role,first=first,last=last,content_last=content_last or last,info=info,block_native=block_native}
   end
   return node
  end
  statement=function(native)
   local first,last,info=span(native);if tokens[last].value==';' then last=last-1 end
   local content_last=last
   if tokens[last+1] and tokens[last+1].value==';' then last=last+1 end
   return ref(native,info.kind=='function_call' and 'call_statement' or nil,first,last,content_last)
  end
  block=function(native,parent,first,boundary,role)
   return ref(native or parent,role or 'block',first,boundary-1,boundary-1,native or false)
  end
  local function refs(native,binding)
   local out={};for _,child in ipairs(named(native)) do out[#out+1]=ref(child,binding and 'binding' or nil) end;return out
  end
  local function assignment(native) return one(native,'variable_list'),one(native,'expression_list') end
  local function declarations(n)
   if n.kind=='local_function' then
    return {names={ref(get(n.native,'name',true),'binding')},values={ref(n.native,'function',n.first+1,n.content_last)},self_visible=true}
   end
   local parts=named(n.native);check(#parts==1,'local declaration shape')
   local variables,values
   if revision:Info(parts[1]).kind=='assignment_statement' then variables,values=assignment(parts[1])
   else check(revision:Info(parts[1]).kind=='variable_list','local variable list');variables=parts[1] end
   return {names=refs(variables,true),values=refs(values),self_visible=false}
  end
  local function function_parts(n)
   local parameters=get(n.native,'parameters',true);local open,close=span(parameters)
   check(tokens[open].value=='(' and tokens[close].value==')','function parameter delimiters')
   local params,vararg={},false
   for _,p in ipairs(named(parameters)) do
    check(not vararg,'parameter after vararg')
    if revision:Info(p).kind=='vararg_expression' then vararg=true else params[#params+1]=ref(p,'binding') end
   end
   check(tokens[n.last].value=='end','function end')
   return {params=params,vararg=vararg,body=block(get(n.native,'body'),n.native,close+1,n.last)},open
  end
  local function call(node,native)
   local callee=ref(get(native,'name',true));local args=refs(get(native,'arguments',true))
   return {node=node,callee=callee,args=args,method=entry(callee).info.kind=='method_index_expression'}
  end
  local function if_parts(n)
   local alternatives=fields(n.native,'alternative');local clauses={}
   local then_at=marker(n.native,'then');local boundary=alternatives[1] and span(alternatives[1]) or n.content_last
   clauses[1]={condition=ref(get(n.native,'condition',true)),body=block(get(n.native,'consequence'),n.native,then_at+1,boundary)}
   local otherwise
   for i,alternative in ipairs(alternatives) do
    local first=span(alternative);local stop=alternatives[i+1] and span(alternatives[i+1]) or n.content_last
    if revision:Info(alternative).kind=='elseif_statement' then
     check(not otherwise,'elseif after else');then_at=marker(alternative,'then')
     clauses[#clauses+1]={condition=ref(get(alternative,'condition',true)),body=block(get(alternative,'consequence'),alternative,then_at+1,stop)}
    else
     check(revision:Info(alternative).kind=='else_statement' and not otherwise and i==#alternatives,'else shape')
     otherwise=block(get(alternative,'body'),alternative,first+1,stop)
    end
   end
   return clauses,otherwise
  end
  local function for_parts(n)
   local clause=get(n.native,'clause',true);local names,values
   if n.kind=='for_numeric' then
    names={ref(get(clause,'name',true),'binding')};values={ref(get(clause,'start',true)),ref(get(clause,'end',true))}
    local step=get(clause,'step');if step then values[#values+1]=ref(step) end
   else
    check(revision:Info(clause).kind=='for_generic_clause','for clause')
    names=refs(one(clause,'variable_list'),true);values=refs(one(clause,'expression_list'))
   end
   local start=marker(n.native,'do')
   return names,values,block(get(n.native,'body'),n.native,start+1,n.content_last)
  end
  match=function(node,pattern)
   local n=entry(node);local native=n.native
   if pattern=='declaration' then
    if n.kind=='local' or n.kind=='local_function' then return declarations(n) end
   elseif pattern=='assignment' then
    if n.kind=='assign' then local variables,values=assignment(native);return {targets=refs(variables),values=refs(values)} end
   elseif pattern=='definition' then
    local target,fn,method,self_visible,form
    if n.kind=='local_function' then
     local d=declarations(n);target,fn,self_visible,form=d.names[1],d.values[1],true,'local-function'
    elseif n.kind=='function_statement' then
     target=ref(get(native,'name',true));fn=ref(native,'function',n.first,n.content_last)
     method=entry(target).info.kind=='method_index_expression';form='function-statement'
    elseif n.kind=='local' then
     local d=declarations(n)
     if #d.names==1 and #d.values==1 and entry(d.values[1]).kind=='function' then target,fn,form=d.names[1],d.values[1],'local-initializer' end
    elseif n.kind=='assign' then
     local a=match(node,'assignment')
     if #a.targets==1 and #a.values==1 and entry(a.values[1]).kind=='function' then target,fn,form=a.targets[1],a.values[1],'assignment' end
    end
    if fn then return {target=target,fn=fn,method=method==true,self_visible=self_visible==true,form=form} end
   elseif pattern=='member' then
    if n.kind=='member' then
     local method=n.info.kind=='method_index_expression'
     return {base=ref(get(native,'table',true)),name=identifier(get(native,method and 'method' or 'field',true)),separator=method and ':' or '.'}
    end
   elseif pattern=='index' then
    if n.kind=='index' then return {base=ref(get(native,'table',true)),key=ref(get(native,'field',true))} end
   elseif pattern=='call' then if n.kind=='call' then return call(node,native) end
   elseif pattern=='call_statement' then if n.kind=='call_statement' then return call(ref(native,'call'),native) end
   elseif pattern=='literal' then
    if n.kind=='literal' then
     local token=tokens[n.first];local kind=n.info.kind
     check(n.first==n.last and ends[n.last]==n.info.b,'literal boundary')
     if kind=='nil' then check(token.value=='nil','nil token')
     elseif kind=='true' or kind=='false' then check(token.value==kind,'boolean token');kind='boolean'
     else check((kind=='number' or kind=='string') and token.kind==kind,'literal kind') end
     return {category=kind,value=token.literal,raw=token.value}
    end
   elseif pattern=='unary' then if n.kind=='unary' then return {operator=tokens[n.first].value,operand=ref(get(native,'operand',true))} end
   elseif pattern=='table' then
    if n.kind=='table' then
     local out={}
     for _,field in ipairs(named(native)) do
      check(revision:Info(field).kind=='field','table field required')
      local field_node=ref(field);local e=entry(field_node);local key,label
      local native_key=get(field,'name')
      if native_key then if tokens[e.first].value=='[' then key=ref(native_key) else label=identifier(native_key) end end
      local value=ref(get(field,'value',true));check(e.last==entry(value).last,'field boundary')
      out[#out+1]={node=field_node,key=key,name=label,array=key==nil and label==nil,value=value}
     end
     return {fields=out}
    end
   elseif pattern=='function' then if n.kind=='function' then local f=function_parts(n);return f end
   elseif pattern=='return' then
    if n.kind=='return' then local p=named(native);check(#p<=1,'return shape');return {values=refs(p[1])} end
   end
  end
  local function statements(node)
   local n=entry(node);check(n.kind=='block' or n.kind=='chunk','statement sequence required')
   local out={}
   for _,child in ipairs(named(n.block_native)) do if revision:Info(child).kind~='empty_statement' then out[#out+1]=statement(child) end end
   return out
  end
  children=function(node)
   local n=entry(node);local native=n.native;local kind=n.kind
   if kind=='chunk' or kind=='block' then return statements(node)
   elseif kind=='local' or kind=='local_function' then local d=declarations(n);return append(d.names,d.values)
   elseif kind=='assign' then local a=match(node,'assignment');return append(a.targets,a.values)
   elseif kind=='function_statement' then local d=match(node,'definition');return {d.target,d.fn}
   elseif kind=='function' then local f=function_parts(n);f.params[#f.params+1]=f.body;return f.params
   elseif kind=='call_statement' then return {ref(native,'call')}
   elseif kind=='call' then local c=call(node,native);return append({c.callee},c.args)
   elseif kind=='member' then return {ref(get(native,'table',true))}
   elseif kind=='index' then return {ref(get(native,'table',true)),ref(get(native,'field',true))}
   elseif kind=='paren' then local parts=named(native);check(#parts==1,'parenthesized expression');return {ref(parts[1])}
   elseif kind=='unary' then return {ref(get(native,'operand',true))}
   elseif kind=='binary' then return {ref(get(native,'left',true)),ref(get(native,'right',true))}
   elseif kind=='table' then local out={};for _,f in ipairs(match(node,'table').fields) do out[#out+1]=f.node end;return out
   elseif kind=='field' then
    local key=get(native,'name');local value=ref(get(native,'value',true))
    return key and tokens[n.first].value=='[' and {ref(key),value} or {value}
   elseif kind=='return' then return match(node,'return').values
   elseif kind=='do' then return {block(get(native,'body'),native,n.first+1,n.content_last)}
   elseif kind=='while' then local at=marker(native,'do');return {ref(get(native,'condition',true)),block(get(native,'body'),native,at+1,n.content_last)}
   elseif kind=='repeat' then local at=marker(native,'until');return {block(get(native,'body'),native,n.first+1,at),ref(get(native,'condition',true))}
   elseif kind=='for_numeric' or kind=='for_generic' then local names,values,body=for_parts(n);append(names,values);names[#names+1]=body;return names
   elseif kind=='if' then
    local clauses,otherwise=if_parts(n);local out={}
    for _,clause in ipairs(clauses) do out[#out+1]=clause.condition;out[#out+1]=clause.body end
    if otherwise then out[#out+1]=otherwise end;return out
   end
   return {}
  end
  -- One full support pass, without constructing a second recursive tree.
  local expression,core,prefix,validate_block,validate_statement,validate_function
  local function budget(level) check(level<=160,'analysis nesting limit exceeded');return level end
  local function check_bindings(values) for _,node in ipairs(values) do identifier(entry(node).native) end end
  validate_function=function(node,level)
   local f=function_parts(entry(node));check_bindings(f.params);validate_block(f.body,level,0,f.vararg)
  end
  prefix=function(node,level,loops,vararg)
   local chain={};local n=entry(node)
   while n.kind=='member' or n.kind=='index' or n.kind=='call' do
    chain[#chain+1]=node
    node=n.kind=='call' and match(node,'call').callee or ref(get(n.native,'table',true));n=entry(node)
   end
   if n.kind=='name' then identifier(n.native)
   elseif n.kind=='paren' then expression(children(node)[1],level,loops,vararg)
   else check(false,'unsupported prefix '..n.kind) end
   for i=#chain,1,-1 do
    node=chain[i];n=entry(node)
    if n.kind=='member' then match(node,'member')
    elseif n.kind=='index' then expression(match(node,'index').key,level,loops,vararg)
    else
     local args=get(n.native,'arguments',true);local open=span(args);local call_parts=match(node,'call')
     if tokens[open].value=='(' then
      local before=check(tokens[open-1],'call prefix')
      check(not source:sub(before.pos+#before.value,tokens[open].pos-1):find('[\r\n]'),'ambiguous newline before call arguments')
      for _,arg in ipairs(call_parts.args) do expression(arg,level,loops,vararg) end
     else
      check(#call_parts.args==1,'call sugar arguments');local arg=call_parts.args[1];local k=entry(arg).kind
      check(k=='table' or (k=='literal' and entry(arg).info.kind=='string'),'call sugar type');core(arg,level,loops,vararg)
     end
    end
   end
  end
  core=function(node,level,loops,vararg)
   local n=entry(node);local kind=n.kind
   if kind=='name' or kind=='paren' or kind=='member' or kind=='index' or kind=='call' then prefix(node,level,loops,vararg)
   elseif kind=='literal' then match(node,'literal')
   elseif kind=='vararg' then check(vararg and n.first==n.last and tokens[n.first].value=='...','vararg outside vararg function')
   elseif kind=='function' then validate_function(node,level)
   elseif kind=='table' then
    check(tokens[n.first].value=='{' and tokens[n.last].value=='}','table delimiters')
    for _,f in ipairs(match(node,'table').fields) do
     if f.key then expression(f.key,level,loops,vararg) end
     expression(f.value,level,loops,vararg)
    end
   elseif kind=='unary' then local u=match(node,'unary');check(unaries[u.operator],'unsupported unary operator');expression(u.operand,level,loops,vararg)
   elseif kind=='binary' then
    local chain={}
    while entry(node).kind=='binary' do chain[#chain+1]=node;node=ref(get(entry(node).native,'left',true)) end
    core(node,level,loops,vararg)
    for i=#chain,1,-1 do
     local e=entry(chain[i]);local left,right=ref(get(e.native,'left',true)),ref(get(e.native,'right',true))
     local at=entry(right).first;check(binaries[tokens[at-1].value] and entry(left).last+2==at,'unsupported binary operator/boundary')
     expression(right,level,loops,vararg)
    end
   else check(false,'unsupported expression '..kind) end
  end
  expression=function(node,level,loops,vararg) core(node,budget(level+1),loops,vararg) end
  validate_statement=function(node,level,loops,vararg)
   local n=entry(node);local kind=n.kind
   if kind=='local' then
    local d=declarations(n);check_bindings(d.names);for _,value in ipairs(d.values) do expression(value,level,loops,vararg) end
   elseif kind=='local_function' or kind=='function_statement' then
    local d=match(node,'definition')
    if kind=='local_function' then identifier(entry(d.target).native) else prefix(d.target,level,loops,vararg) end
    validate_function(d.fn,level)
   elseif kind=='assign' then
    local a=match(node,'assignment')
    for _,target in ipairs(a.targets) do local k=entry(target).kind;check(k=='name' or k=='member' or k=='index','assignment target');prefix(target,level,loops,vararg) end
    for _,value in ipairs(a.values) do expression(value,level,loops,vararg) end
   elseif kind=='call_statement' then prefix(match(node,'call_statement').node,level,loops,vararg)
   elseif kind=='return' then for _,value in ipairs(match(node,'return').values) do expression(value,level,loops,vararg) end;return true
   elseif kind=='break' then check(loops>0,'break outside loop');return true
   elseif kind=='do' then validate_block(children(node)[1],level,loops,vararg)
   elseif kind=='while' then local c=children(node);expression(c[1],level,loops,vararg);validate_block(c[2],level,loops+1,vararg)
   elseif kind=='repeat' then local c=children(node);validate_block(c[1],level,loops+1,vararg);expression(c[2],level,loops,vararg)
   elseif kind=='for_numeric' or kind=='for_generic' then
    local names,values,body=for_parts(n);check_bindings(names)
    for _,value in ipairs(values) do expression(value,level,loops,vararg) end
    validate_block(body,level,loops+1,vararg)
   elseif kind=='if' then
    local clauses,otherwise=if_parts(n)
    for _,c in ipairs(clauses) do expression(c.condition,level,loops,vararg);validate_block(c.body,level,loops,vararg) end
    if otherwise then validate_block(otherwise,level,loops,vararg) end
   else check(false,'unsupported statement '..kind) end
  end
  validate_block=function(node,level,loops,vararg)
   level=budget(level+1);local n=entry(node);local cursor,laststat,prior=n.first,false,nil
   for _,child in ipairs(named(n.block_native)) do
    local begin,finish,info=span(child)
    if info.kind=='empty_statement' then check(begin==finish and prior and entry(prior).last==begin and cursor==begin+1,'independent/repeated semicolon')
    else
     check(not laststat and begin==cursor,'non-contiguous statement or statement after return/break')
     local current=statement(child);check(entry(current).last<=n.last,'statement overlaps block delimiter')
     laststat=validate_statement(current,level,loops,vararg);cursor=entry(current).last+1;prior=current
    end
   end
   check(cursor==n.last+1,'uncovered block tokens')
  end
  s.match,s.children,s.statements,s.function_parts=match,children,statements,function_parts
  s.identifier=function(node) local n=entry(node);if n.kind=='name' or n.kind=='binding' then return identifier(n.native),n.kind=='binding' end end
  local native=revision:Root();local info=revision:Info(native)
  check(info.kind=='chunk' and not info.invalid and info.a>=0 and info.b<=#source,'invalid native whole tree')
  s.root=block(native,native,1,#tokens+1,'chunk');validate_block(s.root,0,0,true)
  return s.root
 end)
 if not ok then
  if revision then revision:Close() end
  if fresh_session and session then session:Close() end
  return nil,tostring(result)
 end
 snapshots[s]=true;return result
end
function T.Match(node,pattern)
 if not patterns[pattern] then error('syntax: unknown match pattern '..tostring(pattern),2) end
 if node==nil then return nil end
 return owner(node).match(node,pattern)
end
function T.Is(node,role)
 if not roles[role] then error('syntax: unknown node role '..tostring(role),2) end
 if node==nil then return false end
 return owner(node).entries[node].kind==role
end
function T.Identifier(node) if node~=nil then return owner(node).identifier(node) end end
function T.IsName(node,name) return T.Is(node,'name') and T.Identifier(node)==name or false end
function T.String(node) local v=T.Match(node,'literal');if v and v.category=='string' then return v.value end end
function T.Range(node) local n=owner(node).entries[node];return n.first,n.last,n.content_last end
function T.ContentLast(node) local _,_,last=T.Range(node);return last end
function T.Statements(node) return owner(node).statements(node) end
function T.Walk(node,visit)
 if node==nil then return end
 assert(type(visit)=='function','syntax visitor required')
 local s=owner(node)
 local function walk(current,parent,functions,calls)
  local kind=s.entries[current].kind
  if kind=='function' then functions=functions+1 end
  if kind=='call' then calls=calls+1 end
  if visit(current,parent,functions,calls)==false then return end
  for _,child in ipairs(s.children(current)) do walk(child,current,functions,calls) end
 end
 walk(node,nil,0,0)
end
function T.Names(node)
 local out={};T.Walk(node,function(n) if T.Is(n,'name') then out[#out+1]=n end end);return out
end
function T.Path(node)
 if T.Is(node,'name') then local name=T.Identifier(node);return name end
 local m=T.Match(node,'member');if m then local base=T.Path(m.base);if base then return base..m.separator..m.name end end
end
function T.Root(node)
 if T.Is(node,'name') then local name=T.Identifier(node);return name end
 local m=T.Match(node,'member') or T.Match(node,'index');if m then return T.Root(m.base) end
end
function T.SingleAssignment(node)
 local a=T.Match(node,'assignment');if a and #a.targets==1 and #a.values==1 then return a.targets[1],a.values[1] end
end
local function signature(s,first,last)
 local out={};for i=first,last do local t=s.tokens[i];out[#out+1]=t.kind..':'..#t.value..':'..t.value end
 return table.concat(out,'|')
end
function T.Text(node)
 local s=owner(node);local n=s.entries[node]
 if n.first>n.last then return '' end
 local first,last=s.tokens[n.first],s.tokens[n.last];return s.source:sub(first.pos,last.pos+#last.value-1)
end
function T.Display(node)
 local s=owner(node);local n=s.entries[node];local out={}
 for i=n.first,n.last do out[#out+1]=s.tokens[i].value end;return table.concat(out)
end
function T.Signature(node) local s=owner(node);local n=s.entries[node];return signature(s,n.first,n.content_last) end
local function function_text(node,method,as_signature)
 local s=owner(node);local n=s.entries[node];check(n.kind=='function','function required')
 local f,open=s.function_parts(n)
 if as_signature then
  local prefix='word:8:function|symbol:1:('
  if method then prefix=prefix..'|word:4:self';if #f.params>0 or f.vararg then prefix=prefix..'|symbol:1:,' end end
  return prefix..'|'..signature(s,open+1,n.last)
 end
 local last=s.tokens[n.last];local tail=s.source:sub(s.tokens[open].pos+1,last.pos+#last.value-1)
 if method then tail='self'..((#f.params>0 or f.vararg) and ',' or '')..tail end
 return 'function('..tail
end
function T.FunctionSource(node,method) return function_text(node,method,false) end
function T.FunctionSignature(node,method) return function_text(node,method,true) end
function T.RetainParser(root)
 local s=owner(root)
 check(s.root==root,'source root required')
 return Native.Retain(s.revision.session)
end
return T
