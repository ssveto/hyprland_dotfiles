--!nonstrict
-- Bar widget: a keyboard glyph that toggles the cheatsheet panel.

local PANEL_ID = "local/sway-keybinds:cheatsheet"

barWidget.setGlyph(noctalia.getConfig("glyph") or "keyboard")
barWidget.setTooltip(noctalia.tr("widget.tooltip"))

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onIpc(event)
  if event == "toggle" then
    noctalia.togglePanel(PANEL_ID)
  end
end
