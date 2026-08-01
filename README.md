# dist/cs_portable.lua

Shareable build of `scripts/cs_adminv2.lua`. Rebuild with:

```bash
tools/build_admin.sh      # refresh the engine payload
tools/build_portable.sh   # -> dist/cs_portable.lua
```

## Why a separate file

`cs_adminv2.lua` is already self-contained — the engine (`cs_core`,
`cs_classes`, `cs_projectile_forge`) travels inside it as a string payload, and
every `readfile`/`writefile` call is optional and `pcall`-guarded. One thing was
not portable: hot reload polls the executor workspace for a file named
`cs_adminv2.lua` every 3s and executes it. On another machine that file is
either missing (an unactionable WARN) or an unrelated/stale copy that would get
run. The portable build compiles that watcher out; everything else is identical.

`reload` stays in the command list and fails with a message instead of
disappearing from `help`.

## Injecting

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/<user>/<repo>/main/cs_portable.lua"))()
```

Needs an executor with `HttpGet` and `loadstring`. Config persistence
(`cs_admin_config.txt`, `cs_engine_caps.txt`) needs `writefile`; without it the
script runs fine and just does not remember settings between sessions.

`raw.githubusercontent.com` caches for ~5 min, so a push is not instantly live.
