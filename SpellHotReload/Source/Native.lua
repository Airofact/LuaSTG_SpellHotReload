-- Native tree-sitter access. Parser lifetime is independent of tree pins.
local ffi=require('ffi')
local bit=require('bit')
ffi.cdef[[
typedef struct TSParser TSParser;
typedef struct TSTree TSTree;
typedef struct TSLanguage TSLanguage;
typedef struct { uint32_t row, column; } TSPoint;
typedef struct { uint32_t context[4]; const void *id; const TSTree *tree; } TSNode;
typedef struct {
 uint32_t start_byte, old_end_byte, new_end_byte;
 TSPoint start_point, old_end_point, new_end_point;
} TSInputEdit;
typedef struct { TSPoint start_point, end_point; uint32_t start_byte, end_byte; } TSRange;
typedef struct {
 const char *type;
 uint32_t symbol, grammar_symbol, named, extra, error, missing, has_error;
 uint32_t start_byte, end_byte, start_row, start_column, end_row, end_column;
 uint32_t children;
} DimsInfo;
const TSLanguage *tree_sitter_lua(void);
uint32_t ts_language_abi_version(const TSLanguage *);
TSParser *ts_parser_new(void);
void ts_parser_delete(TSParser *);
bool ts_parser_set_language(TSParser *, const TSLanguage *);
TSTree *ts_parser_parse_string(TSParser *, const TSTree *, const char *, uint32_t);
TSTree *ts_tree_copy(const TSTree *);
void ts_tree_edit(TSTree *, const TSInputEdit *);
void ts_tree_delete(TSTree *);
uint32_t dims_layout(uint32_t *, uint32_t);
void dims_root(const TSTree *, TSNode *);
void dims_child(const TSNode *, uint32_t, TSNode *);
const char *dims_field(const TSNode *, uint32_t);
void dims_info(const TSNode *, DimsInfo *);
]]
local M,Session,Revision={},{},{}
Session.__index,Revision.__index=Session,Revision
local function point(source,stop)
 local row,last,at=0,0,1
 while true do
  local found=source:find('\n',at,true)
  if not found or found>stop then return row,stop-last end
  row,last,at=row+1,found,found+1
 end
end
local function continuation(byte) return byte and byte>=128 and byte<192 end
local function enclosing(old,new)
 local start,limit=0,math.min(#old,#new)
 while start<limit and old:byte(start+1)==new:byte(start+1) do start=start+1 end
 if start==#old and start==#new then return nil end
 local tail=0
 while tail<limit-start and old:byte(#old-tail)==new:byte(#new-tail) do tail=tail+1 end
 while start>0 and continuation(old:byte(start+1)) do start=start-1 end
 while tail>0 and (continuation(old:byte(#old-tail+1)) or continuation(new:byte(#new-tail+1))) do tail=tail-1 end
 local edit=ffi.new('TSInputEdit[1]')
 edit[0].start_byte,edit[0].old_end_byte,edit[0].new_end_byte=start,#old-tail,#new-tail
 edit[0].start_point.row,edit[0].start_point.column=point(old,start)
 edit[0].old_end_point.row,edit[0].old_end_point.column=point(old,#old-tail)
 edit[0].new_end_point.row,edit[0].new_end_point.column=point(new,#new-tail)
 return edit
end
function Revision:Info(node)
 assert(not self.closed,'closed native tree')
 local out=ffi.new('DimsInfo[1]');self.session.lib.dims_info(node,out);local n=out[0]
 return {kind=ffi.string(n.type),a=tonumber(n.start_byte),b=tonumber(n.end_byte),
  named=n.named~=0,extra=n.extra~=0,invalid=n.error~=0 or n.missing~=0 or n.has_error~=0,
  count=tonumber(n.children)}
end
function Revision:Root()
 assert(not self.closed,'closed native tree')
 local node=ffi.new('TSNode[1]');self.session.lib.dims_root(self.pointer,node);return node
end
function Revision:Child(node,index)
 assert(not self.closed,'closed native tree')
 local child=ffi.new('TSNode[1]');self.session.lib.dims_child(node,index,child);return child
end
function Revision:Field(node,index)
 assert(not self.closed,'closed native tree')
 local name=self.session.lib.dims_field(node,index);return name~=nil and ffi.string(name) or ''
end
-- Bucket only: callers must verify the complete identity inside one snapshot.
-- Read the six exact uint32 words (context + id), never round a pointer to double.
local NodeArray=ffi.typeof('TSNode[1]')
function M.IsNode(node) return type(node)=='cdata' and ffi.istype(NodeArray,node) end
function M.Hash(node)
 local words=ffi.cast('const uint32_t *',node);local hash=0
 for i=0,5 do hash=bit.tobit(hash*21+tonumber(words[i])) end
 return hash
end
function M.Equal(a,b)
 local x,y=a[0],b[0]
 return x.id==y.id and x.tree==y.tree and x.context[0]==y.context[0]
  and x.context[1]==y.context[1] and x.context[2]==y.context[2] and x.context[3]==y.context[3]
end
function Revision:Owns(node)
 return not self.closed and M.IsNode(node) and node[0].tree==self.pointer
end
-- Only failed/unexposed trees are closed explicitly. Exposed snapshots use GC pins.
function Revision:Close()
 if not self.closed then
  ffi.gc(self.pointer,nil);self.session.release_tree(self.pointer)
  self.pointer,self.source,self.closed=nil,nil,true
 end
end
local function parse(self,source,prior)
 assert(not self.closed and type(source)=='string' and #source<4294967296,'open parser/text required')
 if prior then assert(prior.session==self and not prior.closed,'foreign or stale previous tree') end
 local working
 if prior then
  working=self.lib.ts_tree_copy(prior.pointer);assert(working~=nil,'copy returned NULL')
  working=ffi.gc(working,self.delete_working)
  local edit=enclosing(prior.source,source)
  if edit then self.lib.ts_tree_edit(working,edit) end
 end
 local ok,tree=pcall(self.lib.ts_parser_parse_string,self.parser,working,source,#source)
 if working then ffi.gc(working,nil);self.delete_working(working) end
 if not ok then error(tree,0) end
 assert(tree~=nil,'parse returned NULL')
 self.counts.trees=self.counts.trees+1;self.counts.parses=self.counts.parses+1
 if prior then self.counts.incremental=self.counts.incremental+1 end
 tree=ffi.gc(tree,self.release_tree)
 return setmetatable({session=self,pointer=tree,source=source,closed=false},Revision)
end
function Session:Parse(source,prior)
 assert(not self.closed and not self.close_requested,'open parser/text required')
 assert(self.active==0,'parser already active')
 self.active=1
 local ok,result=pcall(parse,self,source,prior)
 self.active=0
 if self.close_requested then self:Close() end
 if not ok then error(result,0) end
 return result
end
function Session:Close()
 self.close_requested=true
 if self.active~=0 then return end
 if not self.closed then
  ffi.gc(self.parser,nil);self.release_parser(self.parser);self.parser=nil;self.closed=true
 end
 -- A source, child handle or plan can still pin trees and the DLL after this call.
end
function M.Open(path)
 assert(ffi.os=='Windows' and ffi.arch=='x64','Windows x64 required')
 local lib=ffi.load(assert(path,'explicit DLL path required'))
 local expected={ffi.sizeof('void *'),ffi.sizeof('TSNode'),ffi.offsetof('TSNode','id'),ffi.offsetof('TSNode','tree'),
  ffi.sizeof('TSPoint'),ffi.offsetof('TSPoint','column'),ffi.sizeof('TSInputEdit'),ffi.offsetof('TSInputEdit','old_end_byte'),
  ffi.offsetof('TSInputEdit','new_end_byte'),ffi.offsetof('TSInputEdit','start_point'),ffi.offsetof('TSInputEdit','old_end_point'),
  ffi.offsetof('TSInputEdit','new_end_point'),ffi.sizeof('TSRange'),ffi.offsetof('TSRange','end_point'),
  ffi.offsetof('TSRange','start_byte'),ffi.offsetof('TSRange','end_byte'),ffi.sizeof('DimsInfo'),
  ffi.offsetof('DimsInfo','symbol'),ffi.offsetof('DimsInfo','children'),13,15}
 local actual=ffi.new('uint32_t[32]');assert(lib.dims_layout(actual,32)==#expected)
 for i,value in ipairs(expected) do assert(actual[i-1]==value,'ABI layout mismatch at '..i) end
 local language=lib.tree_sitter_lua();assert(language~=nil and lib.ts_language_abi_version(language)==15,'grammar ABI mismatch')
 local counts={parsers=1,trees=0,parses=0,incremental=0}
 local function release_parser(pointer) lib.ts_parser_delete(pointer);counts.parsers=counts.parsers-1 end
 local function release_tree(pointer) lib.ts_tree_delete(pointer);counts.trees=counts.trees-1 end
 local parser=lib.ts_parser_new();assert(parser~=nil,'parser returned NULL');parser=ffi.gc(parser,release_parser)
 if not lib.ts_parser_set_language(parser,language) then ffi.gc(parser,nil);release_parser(parser);error('grammar refused') end
 return setmetatable({lib=lib,parser=parser,counts=counts,closed=false,active=0,close_requested=false,
  release_parser=release_parser,release_tree=release_tree,delete_working=function(p) lib.ts_tree_delete(p) end},Session)
end
-- Counts never retain their weak session key. Tokens do not point to an owner.
local leases=setmetatable({}, {__mode='k'})
function M.Retain(session)
 if getmetatable(session)~=Session or session.closed or session.close_requested then
  return nil,'analysis parser is retired'
 end
 leases[session]=(leases[session] or 0)+1
 local held=session
 local function finish()
  if not held then return true end
  local current=held;held=nil
  local count=assert(leases[current],'parser lease missing')-1
  if count==0 then leases[current]=nil;current:Close()
  else leases[current]=count end
  return true
 end
 local ok,guard=pcall(function() return ffi.gc(ffi.new('uint8_t[1]'),finish) end)
 if not ok then finish();return nil,tostring(guard) end
 if session.closed or session.close_requested then
  ffi.gc(guard,nil);finish();return nil,'analysis parser is retired'
 end
 return function()
  if guard then ffi.gc(guard,nil);guard=nil end
  return finish()
 end
end
return M
