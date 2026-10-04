--!nonstrict
-- Sway keybind data service.
--
-- Reads the main Sway config, follows `include` directives (including globs),
-- expands `set $var` variables, and parses bindsym / bindcode / bindswitch in
-- both single-line and block form.
--
-- Parsing is chunked across update() ticks so it stays well inside Noctalia's
-- per-callback CPU budget (a full parse fits on load, but not in an IPC/watch
-- callback). Results are published on the plugin state channel once complete.

local ROWS_KEY = "sway-keybinds.rows"
local UPDATED_KEY = "sway-keybinds.updated"
local REFRESH_KEY = "sway-keybinds.refresh-request"

local LINES_PER_TICK = 80
local MAX_DEPTH = 16
local MAX_FILES = 256

-- ---- pretty printing -------------------------------------------------------

local MOD_LABELS = {
  Mod1 = "Alt",
  Mod2 = "NumLock",
  Mod3 = "Mod3",
  Mod4 = "Super",
  Mod5 = "Mod5",
  Super = "Super",
  Meta = "Super",
  Hyper = "Hyper",
}

local KEY_LABELS = {
  Return = "Enter",
  Escape = "Esc",
  space = "Space",
  minus = "-",
  equal = "=",
  plus = "=",
  comma = ",",
  period = ".",
  slash = "/",
  backslash = "\\",
  apostrophe = "'",
  grave = "`",
  Left = "\u{2190}",
  Right = "\u{2192}",
  Up = "\u{2191}",
  Down = "\u{2193}",
  Next = "PgDn",
  Prior = "PgUp",
  Delete = "Del",
  Insert = "Ins",
  Print = "PrtSc",
}

-- XKB keycodes 10..21 -> digits / - / =
local CODE_LABELS = {}
for c = 10, 18 do
  CODE_LABELS[c] = tostring(c - 9)
end
CODE_LABELS[19] = "0"
CODE_LABELS[20] = "-"
CODE_LABELS[21] = "="

-- ---- small helpers ---------------------------------------------------------

local function trim(value)
  if value == nil then
    return ""
  end
  return string.match(value, "^%s*(.-)%s*$")
end

local function splitLines(data)
  local lines = {}
  local start = 1
  while true do
    local nl = string.find(data, "\n", start, true)
    if nl == nil then
      table.insert(lines, string.sub(data, start))
      break
    end
    table.insert(lines, string.sub(data, start, nl - 1))
    start = nl + 1
  end
  return lines
end

local function dirname(path)
  local clean = (path or ""):gsub("/+$", "")
  local parent = string.match(clean, "^(.*)/[^/]*$")
  if parent == nil or parent == "" then
    return "/"
  end
  return parent
end

local function isAbsolute(path)
  return string.sub(path, 1, 1) == "/"
end

-- ---- environment / glob expansion -----------------------------------------

local function expandEnv(path)
  local expanded = string.gsub(path, "%${([%w_]+)}", function(name)
    return noctalia.getenv(name) or ("${" .. name .. "}")
  end)
  expanded = string.gsub(expanded, "%$([%w_]+)", function(name)
    return noctalia.getenv(name) or ("$" .. name)
  end)
  return noctalia.expandPath(expanded)
end

local function globToPattern(pat)
  local out = "^"
  for i = 1, #pat do
    local c = string.sub(pat, i, i)
    if c == "*" then
      out = out .. ".*"
    elseif c == "?" then
      out = out .. "."
    elseif string.match(c, "[%^%$%(%)%%%.%[%]%+%-]") then
      out = out .. "%" .. c
    else
      out = out .. c
    end
  end
  return out .. "$"
end

local function expandGlob(path)
  if not string.find(path, "[*?]") then
    if noctalia.fileExists(path) then
      return { path }
    end
    return {}
  end

  local dir, pat = string.match(path, "^(.*)/([^/]*)$")
  if dir == nil then
    return {}
  end
  local names = noctalia.listDir(dir)
  if type(names) ~= "table" then
    return {}
  end

  local luaPat = globToPattern(pat)
  local out = {}
  table.sort(names)
  for _, name in ipairs(names) do
    if string.match(name, luaPat) then
      table.insert(out, dir .. "/" .. name)
    end
  end
  return out
end

-- ---- variable expansion ----------------------------------------------------

local vars = {}

local function expandVars(value, depth)
  if value == nil or not string.find(value, "$", 1, true) then
    return value
  end
  depth = depth or 0
  if depth > 8 then
    return value
  end

  local changed = false
  value = string.gsub(value, "%${([%w_]+)}", function(name)
    local v = vars[name]
    if v ~= nil then
      changed = true
      return v
    end
    return "${" .. name .. "}"
  end)

  value = string.gsub(value, "%$([%w_]+)", function(name)
    local v = vars[name]
    if v ~= nil then
      changed = true
      return v
    end
    return "$" .. name
  end)

  if changed then
    return expandVars(value, depth + 1)
  end
  return value
end

local function unquote(value)
  local result = trim(value)
  if #result >= 2 then
    local first = string.sub(result, 1, 1)
    local last = string.sub(result, -1)
    if (first == '"' and last == '"') or (first == "'" and last == "'") then
      result = string.sub(result, 2, -2)
    end
  end
  return result
end

-- ---- comment interpretation -----------------------------------------------

local function looksLikeHeader(text)
  if string.sub(text, -1) == ":" then
    return true
  end
  local _, words = string.gsub(text, "%S+", "")
  return words <= 3
    and string.match(text, "^%u") ~= nil
    and string.sub(text, -1) ~= "."
end

-- From a comment block, return (section, description).
local function commentInfo(buf)
  local n = #buf
  if n == 0 then
    return nil, nil
  end
  if n == 1 then
    return nil, buf[1]
  end

  local desc = buf[n]
  local section = nil
  for i = n - 1, 1, -1 do
    if string.sub(buf[i], -1) == ":" then
      section = buf[i]
      break
    end
  end
  if section == nil then
    for i = 1, n - 1 do
      if looksLikeHeader(buf[i]) then
        section = buf[i]
        break
      end
    end
  end
  return section, desc
end

local function headerOf(buf)
  for i = #buf, 1, -1 do
    if string.sub(buf[i], -1) == ":" then
      return (string.gsub(buf[i], ":$", ""))
    end
  end
  for i = 1, #buf do
    if looksLikeHeader(buf[i]) then
      return buf[i]
    end
  end
  return nil
end

-- ---- binding rows ----------------------------------------------------------

local rows = {}
local rowIndex = {}

local function prettyKey(key, kind)
  local tokens = {}
  for token in string.gmatch(key, "[^+]+") do
    table.insert(tokens, token)
  end

  local n = #tokens
  for i = 1, n do
    local token = tokens[i]
    local code = tonumber(token)
    if kind == "bindcode" and i == n and code ~= nil then
      token = CODE_LABELS[code] or ("code " .. token)
    elseif MOD_LABELS[token] ~= nil then
      token = MOD_LABELS[token]
    elseif KEY_LABELS[token] ~= nil then
      token = KEY_LABELS[token]
    elseif #token == 1 then
      token = string.upper(token)
    end
    tokens[i] = token
  end

  return table.concat(tokens, "+")
end

local function addRow(row)
  local key = row.kind .. "|" .. row.rawkey
  local pos = rowIndex[key]
  if pos ~= nil then
    rows[pos] = row
  else
    table.insert(rows, row)
    rowIndex[key] = #rows
  end
end

local function stripFlags(text)
  local flags = {}
  while true do
    local flag, rest = string.match(text, "^%-%-([%w%-]+)%s+(.*)$")
    if flag == nil then
      break
    end
    table.insert(flags, flag)
    text = rest
  end
  return flags, text
end

local function handleBind(kind, flags, body, frame)
  local key, command = string.match(body, "^(%S+)%s*(.*)$")
  if key == nil or key == "{" then
    return
  end

  local bufSection, desc = commentInfo(frame.buf)
  if bufSection ~= nil then
    frame.section = bufSection
  end

  addRow({
    kind = kind,
    rawkey = expandVars(key),
    chord = prettyKey(expandVars(key), kind),
    command = trim(expandVars(command)),
    desc = desc or "",
    section = frame.section or "Keybindings",
    flags = flags,
  })
end

-- ---- chunked, resumable parsing -------------------------------------------

-- A parse session is a stack of file frames (DFS, so includes are processed in
-- place and variables defined earlier stay visible). Only a bounded number of
-- lines is handled per update() tick.

local stack = nil
local filesSeen = 0

local function processLine(frame, line)
  if line == "" then
    if #frame.buf > 0 then
      local header = headerOf(frame.buf)
      if header ~= nil then
        frame.section = header
      end
      frame.buf = {}
    end

  elseif string.sub(line, 1, 1) == "#" then
    local comment = trim((string.gsub(line, "^#+", "")))
    if comment ~= "" then
      table.insert(frame.buf, comment)
    end

  else
    local keyword, rest = string.match(line, "^(%a+)%s+(.*)$")
    local isBind = keyword == "bindsym" or keyword == "bindcode" or keyword == "bindswitch"

    if isBind then
      local flags, body = stripFlags(rest)
      if string.sub(body, 1, 1) == "{" then
        local header = headerOf(frame.buf)
        if header ~= nil then
          frame.section = header
        elseif #frame.buf > 0 then
          frame.section = frame.buf[#frame.buf]
        end
        frame.buf = {}
        frame.blockKind = keyword
        frame.blockFlags = flags
      else
        handleBind(keyword, flags, body, frame)
        frame.buf = {}
      end

    elseif frame.blockKind ~= nil and line == "}" then
      frame.blockKind = nil
      frame.blockFlags = nil

    elseif frame.blockKind ~= nil then
      handleBind(frame.blockKind, frame.blockFlags, line, frame)
      frame.buf = {}

    elseif keyword == "include" then
      local inc = string.gsub(rest, "%s+#.*$", "")
      inc = expandVars(inc)
      inc = expandEnv(inc)
      if not isAbsolute(inc) then
        inc = frame.base .. "/" .. inc
      end
      if frame.depth < MAX_DEPTH then
        local files = expandGlob(inc)
        for i = #files, 1, -1 do
          table.insert(stack, {
            path = files[i],
            depth = frame.depth + 1,
            base = dirname(files[i]),
          })
        end
      end
      frame.buf = {}

    elseif keyword == "set" then
      local name, value = string.match(line, "^set%s+%$(%w+)%s+(.*)$")
      if name ~= nil then
        vars[name] = expandVars(unquote(value))
      end
      frame.buf = {}

    else
      frame.buf = {}
    end
  end
end

local function finishParse()
  noctalia.state.set(ROWS_KEY, rows)
  noctalia.state.set(UPDATED_KEY, os.time())
  noctalia.log("sway-keybinds: parsed " .. tostring(#rows) .. " bindings")

  stack = nil
  noctalia.setUpdateInterval(60000)
end

local function step(budget)
  while budget > 0 and #stack > 0 do
    local frame = stack[#stack]

    if frame.lines == nil then
      budget = budget - 25
      local data = filesSeen >= MAX_FILES and nil or noctalia.readFile(frame.path)
      if type(data) ~= "string" then
        table.remove(stack)
      else
        frame.lines = splitLines(data)
        frame.index = 1
        frame.buf = {}
        frame.section = nil
        frame.blockKind = nil
        frame.blockFlags = nil
        filesSeen = filesSeen + 1
      end

    elseif frame.index > #frame.lines then
      table.remove(stack)

    else
      local line = trim(frame.lines[frame.index])
      frame.index = frame.index + 1
      processLine(frame, line)
      budget = budget - 1
    end
  end

  if #stack == 0 then
    finishParse()
  end
end

local function startParse()
  rows = {}
  rowIndex = {}
  vars = {}
  filesSeen = 0

  local configPath = noctalia.getConfig("sway_config")
  if type(configPath) ~= "string" or trim(configPath) == "" then
    configPath = "~/.config/sway/config"
  end

  local resolved = expandEnv(configPath)

  stack = {
    { path = resolved, depth = 0, base = dirname(resolved) },
  }
  noctalia.setUpdateInterval(16)
end

function update()
  if stack ~= nil then
    step(LINES_PER_TICK)
  end
end

-- ---- lifecycle -------------------------------------------------------------

startParse()

noctalia.state.watch(REFRESH_KEY, function()
  startParse()
end)

function onConfigChanged()
  startParse()
end

function onEnable()
  startParse()
end

function onIpc(event)
  if event == "refresh" then
    startParse()
  end
end
