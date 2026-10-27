-- Native entities, explicit readers and view/range semantics. Not a timing test.
local M={}
function M.run()
 local Source=require('SpellHotReload.Source.FileAnalysis')
 local Native=require('SpellHotReload.Source.Native')
 local ffi=require('ffi')
 local passed=0
 local function eq(a,b,label) assert(a==b,label);passed=passed+1 end
 local function build(text,old) local s,e=Source.Build(text,nil,old);assert(s,e and e.message);return s end
 local s=build('local function f(a,...) return a,... end; f(1)')
 local tree=s.analysis.syntax;local statement=s.analysis.statements[1].syntax
 local definition=tree.Match(statement,'definition');local fn=definition.fn
 eq(type(fn),'cdata','native entity is cdata')
 eq(fn,statement,'declaration and function views share one entity')
 eq(tree.Is(fn,'function'),true,'function view available')
 eq(tree.Is(fn,'local_function'),true,'declaration view available')
 eq(tree.Match(statement,'definition').fn,fn,'interned lookup retains entity')
 local info=tree.Match(fn,'function')
 eq(tree.Identifier(info.params[1]),'a','parameter value')
 eq(tree.Is(info.params[1],'binding'),true,'binding role is a fact')
 eq(info.vararg,true,'vararg parameter fact')
 local first,last=tree.FunctionRange(fn)
 eq(s.analysis.source:sub(first,last),'function f(a,...) return a,... end','function view source range')
 eq(tree.FunctionSource(fn,false),'function(a,...) return a,... end','lowered function source')
 local call=s.analysis.statements[2].syntax
 eq(tree.Match(call,'call_statement').node,call,'call views share entity')
 eq(tree.Match(call,'call').node,call,'expression view available on statement call')
 eq(Source.Site(s,info.params[1]).statement,1,'nested node resolves existing statement')
 eq(Source.ContainsFact(s,fn),true,'native node is source-owned metadata')
 local copy=ffi.new('TSNode[1]');copy[0]=fn[0]
 eq(Native.Equal(copy,fn),true,'native tuple equality')
 eq(Native.Hash(copy),Native.Hash(fn),'same tuple has same bucket')
 eq(tree.IsNode(copy),false,'unissued raw copy is not an issued query handle')
 eq(Source.ContainsFact(s,copy),true,'copy cannot bypass publication fact rejection')
 local foreign=build(s.content)
 eq(foreign.analysis.syntax.IsNode(fn),false,'foreign snapshot refuses node')
 eq(pcall(foreign.analysis.syntax.Match,fn,'function'),false,'foreign query is explicit error')
 eq(s.analysis.tokens,nil,'no second token index')
 eq(s.analysis.statements[1].tok,nil,'no statement token protocol')
 local same=build(s.content,s)
 eq(same.analysis.syntax.Signature(same.analysis.statements[1].syntax),tree.Signature(statement),'unchanged span content compares exactly')
 local formatted=build('local function f(a,...) return  a,... end; f(1)',same)
 eq(formatted.analysis.syntax.Signature(formatted.analysis.statements[1].syntax)==tree.Signature(statement),false,'formatting within span is an explicit content change')
 local comment=build(s.content..' -- outside statements',formatted)
 eq(comment.analysis.syntax.Signature(comment.analysis.statements[1].syntax),tree.Signature(statement),'outside comment does not change definition content')
 local empty=build('local function empty() end')
 local et=empty.analysis.syntax;local ef=et.Match(empty.analysis.statements[1].syntax,'definition').fn
 eq(#et.Statements(et.Match(ef,'function').body),0,'absent native block has no synthetic wrapper')
 -- Resource checks intentionally collect; ordinary Apply measurements never do.
 local function reader()
  local held=build('local function kept() return 3 end')
  local query=held.analysis.syntax
  local release=assert(Source.Retain(held));local counts=query.revision.session.counts
  local node=query.Match(held.analysis.statements[1].syntax,'definition').fn
  release()
  return query.FunctionSource,node,counts
 end
 local read,node,counts=reader()
 for _=1,3 do collectgarbage('collect') end
 eq(counts.parsers,0,'parser release is independent from reader lifetime')
 eq(read(node,false),'function() return 3 end','explicit reader keeps tree/facts alive')
 eq(counts.trees,1,'reader pins exactly its native tree')
 read,node=nil,nil
 for _=1,3 do collectgarbage('collect') end
 eq(counts.trees,0,'tree retires with the last reader')
 print('NativeSnapshotSpec: '..passed..' passed / 0 failed')
 return {passed=passed,failed=0,failures={}}
end
return M
