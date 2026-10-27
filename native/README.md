# Native syntax backend

Install `dims_tree_sitter_lua.dll` here with the plugin's Lua files. The physical
path from the game working directory is
`plugin/SpellHotReload/native/dims_tree_sitter_lua.dll` (Windows x64 only).
The DLL contains the core, grammar, external scanner and pointer-based bridge;
it is not the standalone Neovim grammar DLL and requires no host `lua_State*`.

The shipped binary is 267200 bytes, SHA-256
`e92540d74d8b2225f3f09e1fa101cf49da0a0848a3f1fd6c598e6736c2ee8e5b`.
Its import table contains KERNEL32.dll and msvcrt.dll. `src/exports.def` lists
all 17 exports. Native.lua validates layout and grammar ABI 15 at load time;
this core supports language ABI 13 through 15.

## Source provenance

- [tree-sitter v0.25.10](https://github.com/tree-sitter/tree-sitter/tree/da6fe9beb4f7f67beb75914ca8e0d48ae48d6406),
  commit `da6fe9beb4f7f67beb75914ca8e0d48ae48d6406`.
- [tree-sitter-lua v0.4.0](https://github.com/tree-sitter-grammars/tree-sitter-lua/tree/4569d1c361129e71a205b94a05e158bd71b1709f),
  commit `4569d1c361129e71a205b94a05e158bd71b1709f`.
- Both are MIT licensed; notices are preserved under `licenses/`.
- `src/bridge.c` and `src/exports.def` are the exact bridge and export inputs
  used for the shipped DLL. No generated grammar source is vendored here.

The grammar's generated lexer needs one CRLF fix: in case 6, before the `u`
branch, add `if (lookahead == '\r') ADVANCE(49);`. CMake checks the original
parser SHA `2be397c6b5094bb7eddb47f285efec0a65dde3f2cdb485de33dc39084e3c7b80`
and writes a patched build-directory copy, checked against SHA
`005d2b0b92a5041a892d11471c20327f48192a82a70271042df0f8113ac387c3`.
Upstream source directories remain read-only.

## Rebuilding

Obtain the exact commits above in separate directories with unchanged LF source
bytes. Supply absolute source roots and the MinGW toolchain explicitly; no
configure-time network access or automatic dependency installation is used.
From the plugin root, for example:

```powershell
cmake -S native -B native-build -G Ninja -DCMAKE_BUILD_TYPE=Release `
  '-DCMAKE_C_COMPILER=C:/toolchain/bin/gcc.exe' `
  '-DCORE_ROOT=C:/deps/tree-sitter' '-DGRAMMAR_ROOT=C:/deps/tree-sitter-lua'
cmake --build native-build
```

The shipped DLL was built with MinGW-w64 GCC 8.1.0 (win32 threads, SEH), Ninja,
C11, Release `-O3 -DNDEBUG`, `TREE_SITTER_REUSE_ALLOCATOR` and `-static-libgcc`.
This recipe preserves those source/ABI choices. The portable recipe itself has
not yet been executed; rebuilding with other paths/tool versions need not yield
the identical PE bytes. Verify exports, imports, layout and regression results
before distributing a rebuilt DLL. Copying/rebuilding is a separate deployment
operation, never an automatic action of the parser.
