#!/bin/sh
# Layout-preserving "maximize" for Sway (closest match to Hyprland's maximize).
#
# Sway has no native maximize state. This keeps the focused window tiled (so the
# application is never told "fullscreen" and keeps its own chrome) while an
# on-demand placeholder window holds the window's exact slot in the tiling tree.
#
# The maximize workspace is then "linked" to the workspace it was invoked from
# by handing over the workspace name: the origin workspace is renamed aside to a
# hold workspace that keeps the other windows + the placeholder, and the window
# itself ends up on a workspace with the original name. So Super+2 (or clicking
# workspace 2) returns to the maximized window, exactly as if it never left.
#
# The placeholder is redirected off-screen the instant it maps (see the
# for_window rule in config.d/zz-user-binds), so there is no visible pop-up.

set -eu

# Serialize toggles so a quick double-press can't run two swaps at once.
if command -v flock >/dev/null 2>&1; then
	exec 9>"${XDG_RUNTIME_DIR:-/tmp}/sway-maximize.lock"
	flock -n 9 || exit 0
fi

MARK='sway-maximized'
AXIS_PREFIX='sway-max-axis-'
WS_PREFIX='sway-max-ws-'
HOLD_PREFIX='sway-max-hold-'
PLACEHOLDER_PREFIX='sway-max-placeholder-'
HOLD_WS_PREFIX='__sway_max_hold_'
RESTORE_TMP_PREFIX='__sway_max_restore_'
STAGING_WS='__sway_maximize_staging'

# Marks left by earlier implementations; cleaned up once so they don't confuse.
OLD_FLOAT_MARK='sway-maximize'
OLD_FULLSCREEN_MARK='sway-maximize-fullscreen'

get_focused() {
	swaymsg -t get_tree \
		| jq -c '.. | objects | select(.focused == true and (.type == "con" or .type == "floating_con"))' \
		| head -n1
}

find_by_app_id() {
	swaymsg -t get_tree \
		| jq -r --arg a "$1" '[.. | objects | select(.app_id == $a)][0].id // empty' \
		| head -n1
}

mark_value() {
	printf '%s' "$1" \
		| jq -r --arg p "$2" '(.marks // [])[] | select(startswith($p)) | ltrimstr($p)' \
		| head -n1
}

focused_ws_name() {
	swaymsg -t get_workspaces | jq -r '.[] | select(.focused == true) | .name' | head -n1
}

ws_exists() {
	swaymsg -t get_workspaces | jq -e --arg n "$1" 'any(.[]; .name == $n)' >/dev/null 2>&1
}

# Wait (bounded) for a workspace to appear/disappear, so a follow-up command
# never races an earlier rename or an asynchronous empty-workspace reap.
wait_ws_present() {
	i=0
	while [ "$i" -lt 100 ]; do
		ws_exists "$1" && return 0
		sleep 0.01
		i=$((i + 1))
	done
	ws_exists "$1"
}

wait_ws_absent() {
	i=0
	while [ "$i" -lt 100 ]; do
		! ws_exists "$1" && return 0
		sleep 0.01
		i=$((i + 1))
	done
	! ws_exists "$1"
}

top_level_ids() {
	swaymsg -t get_tree \
		| jq -r --arg w "$1" \
			'[.. | objects | select(.type == "workspace" and .name == $w)][0] | ((.nodes // []) + (.floating_nodes // []))[] | .id // empty'
}

unmark_app() {
	app_state="$1"
	app_id2="$2"
	swaymsg -- "[con_id=$app_id2]" "unmark $MARK" >/dev/null 2>&1 || true
	axis2=$(mark_value "$app_state" "$AXIS_PREFIX")
	ws2=$(mark_value "$app_state" "$WS_PREFIX")
	hold2=$(mark_value "$app_state" "$HOLD_PREFIX")
	[ -n "$axis2" ] && swaymsg -- "[con_id=$app_id2]" "unmark ${AXIS_PREFIX}${axis2}" >/dev/null 2>&1 || true
	[ -n "$ws2" ] && swaymsg -- "[con_id=$app_id2]" "unmark ${WS_PREFIX}${ws2}" >/dev/null 2>&1 || true
	[ -n "$hold2" ] && swaymsg -- "[con_id=$app_id2]" "unmark ${HOLD_PREFIX}${hold2}" >/dev/null 2>&1 || true
}

focused=$(get_focused)
[ -n "$focused" ] || exit 0
id=$(printf '%s' "$focused" | jq -r '.id')
type=$(printf '%s' "$focused" | jq -r '.type')
appid=$(printf '%s' "$focused" | jq -r '.app_id // ""')

# Never act on a placeholder window itself.
case "$appid" in
	"$PLACEHOLDER_PREFIX"*) exit 0 ;;
esac

# One-time cleanup of a window left in native fullscreen by an older version.
if printf '%s' "$focused" | jq -e --arg m "$OLD_FULLSCREEN_MARK" \
	'(.marks // []) | index($m) != null' >/dev/null; then
	swaymsg -- "[con_id=$id]" "fullscreen disable, unmark $OLD_FULLSCREEN_MARK"
	focused=$(get_focused)
	[ -n "$focused" ] || exit 0
	id=$(printf '%s' "$focused" | jq -r '.id')
	type=$(printf '%s' "$focused" | jq -r '.type')
fi

# One-time cleanup of a window left floating by an older version.
if printf '%s' "$focused" | jq -e --arg m "$OLD_FLOAT_MARK" \
	'(.marks // []) | index($m) != null' >/dev/null; then
	old_axis=$(mark_value "$focused" 'sway-maximize-axis-')
	width=$(mark_value "$focused" 'sway-maximize-width-')
	height=$(mark_value "$focused" 'sway-maximize-height-')
	if [ -n "$width" ] && [ -n "$height" ]; then
		swaymsg -- "[con_id=$id]" "resize set $width $height px, unmark $OLD_FLOAT_MARK, floating disable"
	else
		swaymsg -- "[con_id=$id]" "unmark $OLD_FLOAT_MARK, floating disable"
	fi
	case "$old_axis" in
		splith|splitv|stacking|tabbed)
			sleep 0.2
			swaymsg -- "[con_id=$id]" "layout $old_axis"
			;;
	esac
	exit 0
fi

# ---- Restore ----------------------------------------------------------------
if printf '%s' "$focused" | jq -e --arg m "$MARK" \
	'(.marks // []) | index($m) != null' >/dev/null; then
	axis=$(mark_value "$focused" "$AXIS_PREFIX")
	original_ws=$(mark_value "$focused" "$WS_PREFIX")
	hold_ws=$(mark_value "$focused" "$HOLD_PREFIX")
	placeholder=$(find_by_app_id "${PLACEHOLDER_PREFIX}${id}")

	unmark_app "$focused" "$id"

	# Guard: if the hold workspace or placeholder was reaped (crash / quick
	# race), we cannot swap back. Leave the window where it is.
	if [ -z "$placeholder" ] || [ -z "$hold_ws" ] || ! ws_exists "$hold_ws"; then
		swaymsg -- "[con_id=$id]" "floating disable" >/dev/null 2>&1 || true
		if [ -n "$axis" ]; then
			case "$axis" in
				splith|splitv|stacking|tabbed)
					sleep 0.2
					swaymsg -- "[con_id=$id]" "layout $axis" >/dev/null 2>&1 || true
					;;
			esac
		fi
		printf '%s\n' 'Maximize state was lost; window restored in place.' >&2
		exit 0
	fi

	# Swap the window back into its exact slot on the hold workspace. The
	# placeholder takes its place on the (still original-named) workspace.
	swaymsg -- "[con_id=$id]" "swap container with con_id $placeholder"

	# Drop the placeholder. Anything opened on the maximized workspace while it
	# was active stays there and is moved over to the hold workspace next.
	swaymsg -- "[con_id=$placeholder]" kill >/dev/null 2>&1 || true

	# Free the original name deterministically (an empty workspace may still be
	# awaiting Sway's async reap), and fold any extra windows into the hold
	# workspace so nothing is lost.
	if [ -n "$original_ws" ] && ws_exists "$original_ws"; then
		restore_tmp="${RESTORE_TMP_PREFIX}${id}_$$"
		swaymsg "rename workspace $original_ws to $restore_tmp" >/dev/null 2>&1 || true
		if wait_ws_present "$restore_tmp"; then
			for n in $(top_level_ids "$restore_tmp"); do
				swaymsg -- "[con_id=$n]" "move container to workspace $hold_ws" >/dev/null 2>&1 || true
			done
		fi
	fi

	# Restore the original workspace name onto the hold workspace.
	if [ -n "$original_ws" ] && ws_exists "$hold_ws"; then
		swaymsg "rename workspace $hold_ws to $original_ws" >/dev/null 2>&1 || true
	fi

	# Guard: only focus things that actually exist.
	if [ -n "$original_ws" ] && ws_exists "$original_ws"; then
		swaymsg "workspace $original_ws" >/dev/null 2>&1 || true
	fi
	swaymsg -- "[con_id=$id]" focus >/dev/null 2>&1 || true

	if [ -n "$axis" ]; then
		case "$axis" in
			splith|splitv|stacking|tabbed)
				sleep 0.2
				swaymsg -- "[con_id=$id]" "layout $axis" >/dev/null 2>&1 || true
				;;
		esac
	fi
	exit 0
fi

# ---- Maximize ---------------------------------------------------------------
# Only tiled windows have a slot worth preserving.
[ "$type" = "con" ] || exit 0

if ! command -v footclient >/dev/null 2>&1; then
	printf '%s\n' 'footclient is required for the maximize placeholder.' >&2
	exit 1
fi

axis=$(swaymsg -t get_tree \
	| jq -r '[.. | objects
		| select(((.nodes // []) + (.floating_nodes // [])) | any(.focused == true))
		| .layout] | last // "splith"')
case "$axis" in
	splith|splitv|stacking|tabbed) ;;
	*) axis=splith ;;
esac
original_ws=$(focused_ws_name)
# Handoff needs a named origin workspace.
[ -n "$original_ws" ] || exit 0

app_id="${PLACEHOLDER_PREFIX}${id}"
hold_ws="${HOLD_WS_PREFIX}${id}_$$"
while ws_exists "$hold_ws"; do
	hold_ws="${hold_ws}_"
done

swaymsg -- "[con_id=$id]" \
	"mark --add $MARK, mark --add ${AXIS_PREFIX}${axis}, mark --add ${WS_PREFIX}${original_ws}, mark --add ${HOLD_PREFIX}${hold_ws}"

# Spawn the placeholder off-screen. The for_window rule moves it to the staging
# workspace during map, so it is never drawn on the current workspace.
footclient --app-id="$app_id" --title='Layout placeholder' \
	--override=cursor.blink=no sleep infinity >/dev/null 2>&1 9>&- &

placeholder=''
i=0
while [ "$i" -lt 200 ]; do
	placeholder=$(find_by_app_id "$app_id")
	[ -n "$placeholder" ] && break
	sleep 0.01
	i=$((i + 1))
done

if [ -z "$placeholder" ]; then
	unmark_app "$focused" "$id"
	printf '%s\n' 'Could not create the maximize placeholder; window left unchanged.' >&2
	exit 1
fi

# Hand the origin workspace name to the maximized window:
#   1. rename origin W -> hold H (the other windows come along),
#   2. move the placeholder onto a fresh workspace named W,
#   3. swap the window and the placeholder,
#   4. focus W.
#
# Guard 1: wait for the rename to actually land before moving the placeholder,
# otherwise Sway could keep the old W alive and the move would target it.
if ! swaymsg "rename workspace $original_ws to $hold_ws" >/dev/null 2>&1 \
	|| ! wait_ws_present "$hold_ws" || ws_exists "$original_ws"; then
	swaymsg -- "[con_id=$placeholder]" kill >/dev/null 2>&1 || true
	unmark_app "$focused" "$id"
	printf '%s\n' 'Workspace handoff failed; window left unchanged.' >&2
	exit 1
fi

swaymsg -- "[con_id=$placeholder]" "move container to workspace $original_ws" >/dev/null 2>&1 || true

# Guard 2: confirm the new W exists before swapping into it; roll back the
# rename if it did not materialize.
if ! wait_ws_present "$original_ws"; then
	swaymsg -- "[con_id=$placeholder]" kill >/dev/null 2>&1 || true
	swaymsg "rename workspace $hold_ws to $original_ws" >/dev/null 2>&1 || true
	unmark_app "$focused" "$id"
	printf '%s\n' 'Could not place the maximize workspace; window left unchanged.' >&2
	exit 1
fi

swaymsg -- "[con_id=$id]" "swap container with con_id $placeholder"
swaymsg "workspace $original_ws" >/dev/null 2>&1 || true
swaymsg -- "[con_id=$id]" focus >/dev/null 2>&1 || true

# Keep the original split orientation; autotiling may react to the placeholder.
sleep 0.2
swaymsg -- "[con_id=$placeholder]" "layout $axis" >/dev/null 2>&1 || true
