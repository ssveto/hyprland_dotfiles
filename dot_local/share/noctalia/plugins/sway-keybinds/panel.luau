--!nonstrict
-- Searchable cheatsheet panel. Renders the rows published by the data service.

local ROWS_KEY = "sway-keybinds.rows"
local REFRESH_KEY = "sway-keybinds.refresh-request"

local rows = {}
local query = ""
local isOpen = false
local openCount = 0

local groupBySection = noctalia.getConfig("group_by_section") ~= false

local function refreshConfig()
  groupBySection = noctalia.getConfig("group_by_section") ~= false
end

local function requestRefresh()
  local generation = tonumber(noctalia.state.get(REFRESH_KEY)) or 0
  noctalia.state.set(REFRESH_KEY, generation + 1)
end

local function filtered()
  if query == "" then
    return rows
  end
  local needle = string.lower(query)
  local out = {}
  for _, row in ipairs(rows) do
    local haystack = string.lower(
      row.chord .. " " .. row.desc .. " " .. row.command .. " " .. row.section
    )
    if string.find(haystack, needle, 1, true) ~= nil then
      table.insert(out, row)
    end
  end
  return out
end

local function chordCapsule(row)
  return ui.row({
    key = "cap-" .. row.kind .. "-" .. row.rawkey,
    fill = "surface_variant",
    radius = 6,
    paddingH = 10,
    paddingV = 4,
    minWidth = 150,
    justify = "center",
  }, {
    ui.label({
      text = row.chord,
      fontWeight = "bold",
      maxLines = 1,
      textAlign = "center",
    }),
  })
end

local function bindingRow(row)
  local primary = row.desc ~= "" and row.desc or row.command
  local secondary = row.desc ~= "" and row.command or ""

  return ui.column({
    key = "row-" .. row.kind .. "-" .. row.rawkey,
    gap = 2,
  }, {
    ui.row({ gap = 10, align = "center" }, {
      chordCapsule(row),
      ui.label({ text = primary, flexGrow = 1, maxLines = 1 }),
    }),
    ui.label({
      text = secondary,
      color = "on_surface_variant",
      fontSize = 12,
      maxLines = 1,
    }),
  })
end

local function listItems(list)
  local items = {}
  local lastSection = nil

  for _, row in ipairs(list) do
    if groupBySection and row.section ~= lastSection then
      lastSection = row.section
      table.insert(items, ui.label({
        key = "section-" .. row.section,
        text = row.section,
        color = "primary",
        fontWeight = "bold",
        fontSize = 13,
      }))
    end
    table.insert(items, bindingRow(row))
  end

  if #list == 0 then
    table.insert(items, ui.label({
      text = noctalia.tr("panel.empty"),
      color = "on_surface_variant",
    }))
  end

  return items
end

local function render()
  local list = filtered()

  -- The root column must flex to the panel's fixed height, otherwise the
  -- scroll below sizes to its content and overflows the panel instead of
  -- scrolling. Key it (and the scroll) so re-renders reuse the same native
  -- controls and keep the scroll offset.
  panel.render(ui.column({ key = "sway-keybinds-root", flexGrow = 1, gap = 12, padding = 16, align = "stretch" }, {
    ui.row({ align = "center", gap = 10 }, {
      ui.glyph({ name = "keyboard", size = 18, color = "primary" }),
      ui.label({
        text = noctalia.tr("panel.title"),
        fontSize = 16,
        fontWeight = "bold",
        flexGrow = 1,
      }),
      ui.label({
        text = noctalia.tr("panel.count", { count = #list }),
        color = "on_surface_variant",
      }),
      ui.button({
        glyph = "refresh",
        variant = "ghost",
        tooltip = noctalia.tr("panel.refresh"),
        onClick = "onRefresh",
      }),
      ui.button({
        glyph = "close",
        variant = "ghost",
        onClick = "onCloseClicked",
      }),
    }),
    ui.input({
      key = "search-" .. openCount,
      placeholder = noctalia.tr("panel.search_placeholder"),
      focus = true,
      onChange = "onSearch",
    }),
    ui.scroll({ key = "sway-keybinds-scroll", flexGrow = 1, gap = 8, align = "stretch" }, listItems(list)),
  }))
end

noctalia.state.watch(ROWS_KEY, function(value)
  rows = value or {}
  if isOpen then
    render()
  end
end)

rows = noctalia.state.get(ROWS_KEY) or {}

function onOpen()
  isOpen = true
  openCount = openCount + 1
  query = ""
  refreshConfig()
  rows = noctalia.state.get(ROWS_KEY) or rows
  requestRefresh()
  render()
end

function onClose()
  isOpen = false
end

function onSearch(text)
  query = text or ""
  render()
end

function onRefresh()
  requestRefresh()
  render()
end

function onCloseClicked()
  panel.close()
end
