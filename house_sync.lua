package.path = "/usr/lib/house-handlers/house_generators/?.lua;/usr/lib/house-handlers/?.lua;" .. package.path

local config = require("config")

local house_sync = {}

-- verbose output
function house_sync.vprint(...)
  io.stderr:write("[v] ")
  io.stderr:write(string.format(...))
  io.stderr:write("\n")
end

-- file I/O helpers
function house_sync.read_file(path)
  house_sync.vprint("read_file %s", path)
  local f, err = io.open(path, "r")
  if not f then
    house_sync.vprint("  → not found")
    return nil
  end
  local c = f:read("*a")
  f:close()
  house_sync.vprint("  → %d bytes", #c)
  return c
end

function house_sync.ensure_dir(dir)
  local f = io.open(dir, "r")
  if f then f:close(); return true end
  io.stderr:write("[warn] creating directory: " .. dir .. "\n")
  return house_sync.shell("mkdir -p '" .. dir .. "'")
end

function house_sync.write_file(path, content)
  house_sync.vprint("write_file %s (%d bytes)", path, #content)
  local dir = path:match("^(.*/)")
  if dir then
    local ok = house_sync.ensure_dir(dir)
    if not ok then return false, "failed to create " .. dir end
  end
  local f, err = io.open(path, "w")
  if not f then return false, err end
  f:write(content)
  f:close()
  return true
end

-- shell helpers
function house_sync.shell(cmd)
  house_sync.vprint("shell: %s", cmd)
  local ok = os.execute(cmd .. " 2>/dev/null")
  return ok
end

function house_sync.shell_output(cmd)
  local f = io.popen(cmd .. " 2>/dev/null")
  if not f then return "" end
  local out = f:read("*a")
  f:close()
  return out:gsub("%s+$", "")
end

-- change builder
function house_sync.change(section, generator, target, detail, apply_fn)
  return {
    type = "~",
    section = section,
    generator = generator,
    target = target,
    detail = detail,
    apply_fn = apply_fn,
  }
end

-- load house generators
local generators = {}
local generator_names = {
  "edit",
  "script",
}

house_sync.vprint("loading house generators...")
for _, name in ipairs(generator_names) do
  local ok, gen = pcall(require, name)
  if ok and type(gen) == "table" then
    table.insert(generators, gen)
    house_sync.vprint("  generator '%s' loaded", name)
  else
    house_sync.vprint("  generator '%s' FAILED: %s", name, tostring(gen))
  end
end
house_sync.vprint("%d generators loaded", #generators)

-- collect all changes
function house_sync.collect(cfg)
  local changes = {}
  for _, gen in ipairs(generators) do
    local name = gen.name or "?"
    house_sync.vprint("planner '%s' running...", name)
    local ok, plans = pcall(gen.plan, cfg, house_sync)
    if ok and plans then
      house_sync.vprint("  → %d changes", #plans)
      for _, c in ipairs(plans) do
        table.insert(changes, c)
      end
    else
      house_sync.vprint("  → ERROR: %s", tostring(plans))
    end
  end
  table.sort(changes, function(a, b)
    local order = { ["+"] = 1, ["~"] = 2, ["-"] = 3 }
    return (order[a.type] or 0) < (order[b.type] or 0)
  end)
  house_sync.vprint("total changes: %d", #changes)
  return changes
end

-- print summary
function house_sync.summary(changes)
  if #changes == 0 then
    print("House is already synchronized — no changes required.")
    return
  end
  local groups = {}
  for _, c in ipairs(changes) do
    local s = c.section or "misc"
    if not groups[s] then groups[s] = {} end
    table.insert(groups[s], c)
  end
  print()
  print("  House Synchronize — Plan")
  print("  " .. string.rep("=", 40))
  print()
  for s, entries in pairs(groups) do
    print("  [" .. s .. "]")
    for _, c in ipairs(entries) do
      local sym = c.type == "+" and " [+] " or c.type == "-" and " [-] " or " [~] "
      print("    " .. sym .. c.target)
      if c.detail then
        print("         " .. c.detail)
      end
    end
    print()
  end
end

-- apply all changes
function house_sync.apply(changes)
  local failures = 0
  for _, c in ipairs(changes) do
    local sym = c.type == "+" and "[+]" or c.type == "-" and "[-]" or "[~]"
    io.stderr:write(string.format("[apply] %s %s/%s\n", sym, c.section or "?", c.target))
    if c.apply_fn then
      local ok, result = pcall(c.apply_fn, c, house_sync)
      if not ok then
        io.stderr:write("[error] " .. tostring(result) .. "\n")
        failures = failures + 1
      elseif result == false then
        io.stderr:write("[error] command failed\n")
        failures = failures + 1
      else
        io.stderr:write("[ok] " .. sym .. " " .. (c.section or "?") .. "/" .. c.target .. "\n")
      end
    end
  end
  if failures > 0 then
    io.stderr:write(string.format("\n[warn] %d change(s) failed — review errors above\n", failures))
  end
  return true, failures
end

-- CLI entry point
if arg and arg[0] and arg[0]:match("house_sync%.lua$") then
  local uid = tonumber((house_sync.shell_output("id -u")))
  if uid ~= 0 then
    io.stderr:write("error: root privileges required\n")
    os.exit(1)
  end

  local cfg_path = arg[1] or "/etc/houses/house.lua"
  house_sync.vprint("loading house config from %s", cfg_path)
  local cfg, err = config.load(cfg_path)
  if not cfg then
    io.stderr:write("error: " .. err .. "\n")
    os.exit(1)
  end

  local changes = house_sync.collect(cfg)
  house_sync.summary(changes)

  if #changes == 0 then os.exit(0) end

  io.write("Proceed with house synchronization? [y/N]: ")
  io.flush()
  local answer = io.read()
  local ok = answer and (answer:lower() == "y" or answer:lower() == "yes")
  if not ok then
    print("Cancelled.")
    os.exit(0)
  end

  print("Applying house changes...")
  local _, failures = house_sync.apply(changes)
  if failures and failures > 0 then
    print("House synchronization finished with " .. failures .. " failure(s).")
    io.stderr:write("No new generation created — fix errors and re-run, or boot a previous generation.\n")
  else
    print("Creating post-sync house generation...")
    if not house_sync.shell("genzee create 'post-sync house'") then
      io.stderr:write("[warn] genzee create failed — house is synced but no new boot entry was added.\n")
      io.stderr:write("        Check btrfs layout (@ / @snapshots) and run: genzee create 'post-sync house'\n")
    end
    print("House synchronization complete.")
  end
end

return house_sync
