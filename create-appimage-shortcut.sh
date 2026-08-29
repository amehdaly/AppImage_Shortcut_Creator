#!/usr/bin/env bash

set -u

TITLE="AppImage Shortcut Creator"
TEMP_DIR=""
SUDO_PASSWORD=""

# ------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------

error_exit() {
    kdialog --title "$TITLE" --error "$1"
    exit 1
}

cleanup() {
    if [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR:-}" ]]; then
        rm -rf "$TEMP_DIR"
    fi

    unset SUDO_PASSWORD 2>/dev/null || true
}

trap cleanup EXIT

sanitize_filename() {
    printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9._-]/-/g' \
        | sed 's/--*/-/g' \
        | sed 's/^-//' \
        | sed 's/-$//'
}

xml_escape() {
    printf '%s' "$1" \
        | sed \
            -e 's/&/\&amp;/g' \
            -e 's/</\&lt;/g' \
            -e 's/>/\&gt;/g' \
            -e 's/"/\&quot;/g' \
            -e "s/'/\&apos;/g"
}

desktop_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g'
}

run_optional_refresh_command() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 15s "$@" >/dev/null 2>&1 || true
    else
        "$@" >/dev/null 2>&1 || true
    fi
}

refresh_desktop_menus() {
    local DESKTOP_DATABASE_DIR="$1"
    local KBUILD_COMMAND=""

    if command -v update-desktop-database >/dev/null 2>&1; then

        if [[ "$NEED_SUDO" == true && ! -w "$DESKTOP_DATABASE_DIR" ]]; then

            printf '%s\n' "$SUDO_PASSWORD" \
                | run_optional_refresh_command \
                    sudo -S -p '' update-desktop-database \
                    -q \
                    "$DESKTOP_DATABASE_DIR"

        else

            run_optional_refresh_command \
                update-desktop-database \
                -q \
                "$DESKTOP_DATABASE_DIR"

        fi

    fi

    if command -v xdg-desktop-menu >/dev/null 2>&1; then
        run_optional_refresh_command xdg-desktop-menu forceupdate
    fi

    if command -v kbuildsycoca6 >/dev/null 2>&1; then
        KBUILD_COMMAND="kbuildsycoca6"
    elif command -v kbuildsycoca5 >/dev/null 2>&1; then
        KBUILD_COMMAND="kbuildsycoca5"
    fi

    if [[ -n "$KBUILD_COMMAND" ]]; then
        run_optional_refresh_command "$KBUILD_COMMAND" --noincremental
    fi
}

# ------------------------------------------------------------
# Scan KDE menu categories
# ------------------------------------------------------------

scan_kde_menu_categories() {
    python3 <<'PY'
import os
import glob
import xml.etree.ElementTree as ET

home = os.path.expanduser("~")

menu_files = [
    "/etc/xdg/menus/plasma-applications.menu",
    "/etc/xdg/menus/applications.menu",
    os.path.join(home, ".config/menus/applications-kmenuedit.menu"),
]

menu_files += glob.glob(
    os.path.join(home, ".config/menus/applications-merged/*.menu")
)

directory_dirs = [
    os.path.join(home, ".local/share/desktop-directories"),
    "/usr/local/share/desktop-directories",
    "/usr/share/desktop-directories",
]

def directory_name(filename):
    if not filename:
        return None

    for base in directory_dirs:
        path = os.path.join(base, filename)

        if not os.path.isfile(path):
            continue

        try:
            names = {}
            with open(path, encoding="utf-8", errors="ignore") as f:
                for line in f:
                    line = line.strip()

                    if line.startswith("Name="):
                        names["default"] = line[5:]

                    elif line.startswith("Name[en]="):
                        names["en"] = line[9:]

            return names.get("default") or names.get("en")

        except OSError:
            pass

    return None


def top_level_application_menus(root):
    for menu in list(root):
        if menu.tag != "Menu":
            continue

        name = (menu.findtext("Name") or "").strip()

        if name != "Applications":
            continue

        for child in list(menu):
            if child.tag != "Menu":
                continue

            label = (child.findtext("Name") or "").strip()

            if not label:
                continue

            if label in {"More", "Applications"}:
                continue

            yield child

    if root.tag == "Menu":
        name = (root.findtext("Name") or "").strip()
        if name == "Applications":
            for child in list(root):
                if child.tag != "Menu":
                    continue

                label = (child.findtext("Name") or "").strip()

                if not label or label in {"More", "Applications"}:
                    continue

                yield child


def menu_include_category(menu):
    include = menu.find("Include")

    if include is None:
        return None

    for category in include.iter("Category"):
        value = (category.text or "").strip()

        if value and value != "X-KDE-More":
            return value

    return None


categories = {}

for menu_file in menu_files:
    if not os.path.isfile(menu_file):
        continue

    try:
        root = ET.parse(menu_file).getroot()
    except Exception:
        continue

    for menu in top_level_application_menus(root):
        label = (menu.findtext("Name") or "").strip()
        category = menu_include_category(menu)

        if not category:
            continue

        display_name = label
        directory_display = directory_name(menu.findtext("Directory"))

        if directory_display:
            display_name = directory_display

        categories.setdefault(category, display_name)

for label, display in sorted(
    categories.items(),
    key=lambda x: x[1].lower()
):
    print(f"{label}\t{display}")
PY
}

# ------------------------------------------------------------
# Dependencies
# ------------------------------------------------------------

for COMMAND in kdialog python3 find file; do

    command -v "$COMMAND" >/dev/null 2>&1 ||
        error_exit "Required command not found:

$COMMAND"

done

# ------------------------------------------------------------
# Select AppImage
# ------------------------------------------------------------

APPIMAGE="$(
    kdialog \
        --title "$TITLE - Select AppImage" \
        --getopenfilename "$HOME" \
        "*.AppImage *.appimage|AppImage files"
)"

[[ -n "$APPIMAGE" ]] || exit 0

[[ -f "$APPIMAGE" ]] ||
    error_exit "The selected AppImage does not exist."

# Ensure AppImage is executable

if [[ ! -x "$APPIMAGE" ]]; then

    if kdialog \
        --title "$TITLE" \
        --yesno \
        "The selected AppImage is not executable.

Make it executable now?"
    then

        chmod +x "$APPIMAGE" ||
            error_exit "Unable to make the AppImage executable."

    else
        exit 0
    fi

fi

# Convert to absolute path

APPIMAGE="$(readlink -f "$APPIMAGE")"

# ------------------------------------------------------------
# Extract AppImage
# ------------------------------------------------------------

TEMP_DIR="$(mktemp -d)" ||
    error_exit "Unable to create temporary directory."

kdialog \
    --title "$TITLE" \
    --passivepopup \
    "Extracting AppImage metadata and icons..." \
    3

(
    cd "$TEMP_DIR" || exit 1
    "$APPIMAGE" --appimage-extract >/dev/null 2>&1
)

[[ -d "$TEMP_DIR/squashfs-root" ]] ||
    error_exit "Unable to extract the AppImage.

The selected file may not support:

--appimage-extract"

ROOT="$TEMP_DIR/squashfs-root"

# ------------------------------------------------------------
# Find embedded .desktop file
# ------------------------------------------------------------

EMBEDDED_DESKTOP="$(
    find "$ROOT" \
        -maxdepth 4 \
        -type f \
        -name "*.desktop" \
        -print \
        2>/dev/null \
        | head -n 1
)"

EMBEDDED_NAME=""
EMBEDDED_ICON=""
EMBEDDED_COMMENT=""
EMBEDDED_MIME=""

if [[ -n "$EMBEDDED_DESKTOP" ]]; then

    EMBEDDED_NAME="$(
        sed -n 's/^Name=//p' "$EMBEDDED_DESKTOP" \
        | head -n 1
    )"

    EMBEDDED_ICON="$(
        sed -n 's/^Icon=//p' "$EMBEDDED_DESKTOP" \
        | head -n 1
    )"

    EMBEDDED_COMMENT="$(
        sed -n 's/^Comment=//p' "$EMBEDDED_DESKTOP" \
        | head -n 1
    )"

    EMBEDDED_MIME="$(
        sed -n 's/^MimeType=//p' "$EMBEDDED_DESKTOP" \
        | head -n 1
    )"

fi

# ------------------------------------------------------------
# Application name
# ------------------------------------------------------------

if [[ -n "$EMBEDDED_NAME" ]]; then
    DEFAULT_NAME="$EMBEDDED_NAME"
else
    DEFAULT_NAME="$(basename "$APPIMAGE")"
    DEFAULT_NAME="${DEFAULT_NAME%.AppImage}"
    DEFAULT_NAME="${DEFAULT_NAME%.appimage}"
fi

APP_NAME="$(
    kdialog \
        --title "$TITLE" \
        --inputbox \
        "Application name:" \
        "$DEFAULT_NAME"
)"

[[ -n "$APP_NAME" ]] || exit 0

SAFE_NAME="$(sanitize_filename "$APP_NAME")"

[[ -n "$SAFE_NAME" ]] ||
    error_exit "Unable to generate a valid launcher filename."

# ------------------------------------------------------------
# Description
# ------------------------------------------------------------

DEFAULT_COMMENT="${EMBEDDED_COMMENT:-Launch $APP_NAME}"

COMMENT="$(
    kdialog \
        --title "$TITLE" \
        --inputbox \
        "Application description:" \
        "$DEFAULT_COMMENT"
)"

[[ -n "$COMMENT" ]] ||
    COMMENT="Launch $APP_NAME"

# ------------------------------------------------------------
# Scan existing KDE menu categories
# ------------------------------------------------------------

mapfile -t MENU_CATEGORIES < <(scan_kde_menu_categories)

if [[ ${#MENU_CATEGORIES[@]} -eq 0 ]]; then

    kdialog \
        --title "$TITLE" \
        --sorry \
        "No existing KDE menu categories could be detected.

You may create a new category."

fi

MENU_ARGS=()

for ENTRY in "${MENU_CATEGORIES[@]}"; do

    CATEGORY_ID="${ENTRY%%$'\t'*}"
    CATEGORY_NAME="${ENTRY#*$'\t'}"

    MENU_ARGS+=(
        "$CATEGORY_ID"
        "$CATEGORY_NAME"
    )

done

MENU_ARGS+=(
    "__CREATE_NEW__"
    "Create New Category..."
)

CATEGORY="$(
    kdialog \
        --title "$TITLE - Menu Category" \
        --menu \
        "Select the application-menu category:" \
        "${MENU_ARGS[@]}"
)"

[[ -n "$CATEGORY" ]] || exit 0

CREATED_NEW_CATEGORY=false

# ------------------------------------------------------------
# Create new KDE menu category
# ------------------------------------------------------------

if [[ "$CATEGORY" == "__CREATE_NEW__" ]]; then

    NEW_CATEGORY_NAME="$(
        kdialog \
            --title "$TITLE - New Menu Category" \
            --inputbox \
            "Enter the name of the new application-menu category:"
    )"

    [[ -n "$NEW_CATEGORY_NAME" ]] || exit 0

    CATEGORY_SLUG="$(
        printf '%s' "$NEW_CATEGORY_NAME" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9]/-/g' \
        | sed 's/--*/-/g' \
        | sed 's/^-//' \
        | sed 's/-$//'
    )"

    [[ -n "$CATEGORY_SLUG" ]] ||
        error_exit "Unable to generate a valid category identifier."

    CATEGORY="X-AppImage-$CATEGORY_SLUG"

    DIRECTORY_DIR="$HOME/.local/share/desktop-directories"
    MERGED_MENU_DIR="$HOME/.config/menus/applications-merged"

    mkdir -p "$DIRECTORY_DIR" "$MERGED_MENU_DIR" ||
        error_exit "Unable to create KDE menu directories."

    DIRECTORY_FILE="$DIRECTORY_DIR/appimage-$CATEGORY_SLUG.directory"

    MENU_FILE="$MERGED_MENU_DIR/appimage-$CATEGORY_SLUG.menu"

    ESCAPED_CATEGORY_NAME="$(desktop_escape "$NEW_CATEGORY_NAME")"
    XML_CATEGORY="$(xml_escape "$CATEGORY")"
    XML_MENU_NAME="$(xml_escape "$CATEGORY_SLUG")"

    # .directory file

    cat > "$DIRECTORY_FILE" <<EOF
[Desktop Entry]
Type=Directory
Name=$ESCAPED_CATEGORY_NAME
Icon=applications-other
EOF

    # Freedesktop menu fragment

    cat > "$MENU_FILE" <<EOF
<!DOCTYPE Menu PUBLIC "-//freedesktop//DTD Menu 1.0//EN"
"http://www.freedesktop.org/standards/menu-spec/menu-1.0.dtd">

<Menu>

    <Name>Applications</Name>

    <Menu>

        <Name>$XML_MENU_NAME</Name>

        <Directory>appimage-$CATEGORY_SLUG.directory</Directory>

        <Include>
            <Category>$XML_CATEGORY</Category>
        </Include>

    </Menu>

</Menu>
EOF

    CREATED_NEW_CATEGORY=true

fi

# ------------------------------------------------------------
# Icon destination
# ------------------------------------------------------------

DEFAULT_ICON_DIR="$HOME/.local/share/icons/appimages"

mkdir -p "$DEFAULT_ICON_DIR" 2>/dev/null || true

ICON_DIR="$(
    kdialog \
        --title "$TITLE - Icon Location" \
        --getexistingdirectory "$DEFAULT_ICON_DIR"
)"

[[ -n "$ICON_DIR" ]] || exit 0

ICON_DIR="$(readlink -f "$ICON_DIR")"

# ------------------------------------------------------------
# Launcher scope
# ------------------------------------------------------------

SCOPE="$(
    kdialog \
        --title "$TITLE - Launcher Location" \
        --radiolist \
        "Where should the launcher be installed?" \
        "user" \
        "Current user only (~/.local/share/applications)" \
        on \
        "system" \
        "System-wide (/usr/share/applications)" \
        off
)"

[[ -n "$SCOPE" ]] || exit 0

if [[ "$SCOPE" == "system" ]]; then

    DESKTOP_DIR="/usr/share/applications"

else

    DESKTOP_DIR="$HOME/.local/share/applications"

fi

DESKTOP_FILE="$DESKTOP_DIR/$SAFE_NAME.desktop"

# ------------------------------------------------------------
# Determine whether sudo is required
# ------------------------------------------------------------

NEED_SUDO=false

if [[ "$SCOPE" == "system" ]]; then
    NEED_SUDO=true
fi

if [[ -e "$ICON_DIR" ]]; then

    [[ -w "$ICON_DIR" ]] ||
        NEED_SUDO=true

else

    PARENT="$ICON_DIR"

    while [[ ! -e "$PARENT" && "$PARENT" != "/" ]]; do
        PARENT="$(dirname "$PARENT")"
    done

    [[ -w "$PARENT" ]] ||
        NEED_SUDO=true

fi

# ------------------------------------------------------------
# Obtain and validate sudo password
# ------------------------------------------------------------

if [[ "$NEED_SUDO" == true ]]; then

    SUDO_PASSWORD="$(
        kdialog \
            --title "$TITLE - Administrator Permission" \
            --password \
            "Administrator permission is required.

Enter your sudo password:"
    )"

    [[ -n "$SUDO_PASSWORD" ]] || exit 0

    if ! printf '%s\n' "$SUDO_PASSWORD" \
        | sudo -S -p '' -v >/dev/null 2>&1
    then

        unset SUDO_PASSWORD

        error_exit "The sudo password is incorrect."

    fi

fi

# ------------------------------------------------------------
# Create destination directories
# ------------------------------------------------------------

if [[ ! -d "$ICON_DIR" ]]; then

    if [[ "$NEED_SUDO" == true ]]; then

        printf '%s\n' "$SUDO_PASSWORD" \
            | sudo -S -p '' mkdir -p "$ICON_DIR"

    else

        mkdir -p "$ICON_DIR"

    fi

fi

if [[ "$SCOPE" == "system" ]]; then

    printf '%s\n' "$SUDO_PASSWORD" \
        | sudo -S -p '' mkdir -p "$DESKTOP_DIR"

else

    mkdir -p "$DESKTOP_DIR"

fi

# ------------------------------------------------------------
# Find embedded icons
# ------------------------------------------------------------

ICON_CANDIDATES=()

add_icon_candidate() {

    local ICON="$1"

    [[ -f "$ICON" ]] || return

    for EXISTING in "${ICON_CANDIDATES[@]}"; do

        [[ "$EXISTING" == "$ICON" ]] &&
            return

    done

    ICON_CANDIDATES+=("$ICON")
}

# Prefer icon referenced by embedded desktop file

if [[ -n "$EMBEDDED_ICON" ]]; then

    while IFS= read -r ICON; do

        add_icon_candidate "$ICON"

    done < <(
        find "$ROOT" \
            -type f \
            \( \
                -iname "$EMBEDDED_ICON.png" \
                -o -iname "$EMBEDDED_ICON.svg" \
                -o -iname "$EMBEDDED_ICON.xpm" \
            \) \
            2>/dev/null
    )

fi

# Standard AppImage icon locations

while IFS= read -r ICON; do

    add_icon_candidate "$ICON"

done < <(
    find "$ROOT" \
        -type f \
        \( \
            -path "*/share/icons/*/apps/*.png" \
            -o -path "*/share/icons/*/apps/*.svg" \
            -o -path "*/share/icons/*/apps/*.xpm" \
            -o -path "*/share/pixmaps/*.png" \
            -o -path "*/share/pixmaps/*.svg" \
            -o -path "*/share/pixmaps/*.xpm" \
            -o -name ".DirIcon" \
        \) \
        2>/dev/null
)

# ------------------------------------------------------------
# Copy icons
# ------------------------------------------------------------

MAIN_ICON=""
ICON_NUMBER=0
MAIN_ICON_PRIORITY=0

for SOURCE_ICON in "${ICON_CANDIDATES[@]}"; do

    [[ -f "$SOURCE_ICON" ]] || continue

    MIME_TYPE="$(
        file -b --mime-type "$SOURCE_ICON" 2>/dev/null || true
    )"

    case "$MIME_TYPE" in

        image/svg+xml)
            EXT="svg"
            PRIORITY=100
            ;;

        image/png)
            EXT="png"
            PRIORITY=80
            ;;

        image/x-xpixmap)
            EXT="xpm"
            PRIORITY=20
            ;;

        *)
            continue
            ;;

    esac

    ((++ICON_NUMBER))

    DEST_ICON="$ICON_DIR/${SAFE_NAME}-${ICON_NUMBER}.${EXT}"

    if [[ "$NEED_SUDO" == true && ! -w "$ICON_DIR" ]]; then

        printf '%s\n' "$SUDO_PASSWORD" \
            | sudo -S -p '' cp "$SOURCE_ICON" "$DEST_ICON"

        printf '%s\n' "$SUDO_PASSWORD" \
            | sudo -S -p '' chmod 644 "$DEST_ICON"

    else

        cp "$SOURCE_ICON" "$DEST_ICON"
        chmod 644 "$DEST_ICON"

    fi

    if (( PRIORITY > MAIN_ICON_PRIORITY )); then

        MAIN_ICON="$DEST_ICON"
        MAIN_ICON_PRIORITY="$PRIORITY"

    fi

done

# ------------------------------------------------------------
# No icon found
# ------------------------------------------------------------

if [[ -z "$MAIN_ICON" ]]; then

    if kdialog \
        --title "$TITLE" \
        --yesno \
        "No usable application icon was found inside the AppImage.

Use a generic executable icon instead?"
    then

        MAIN_ICON="application-x-executable"

    else

        exit 0

    fi

fi

# ------------------------------------------------------------
# Build .desktop file
# ------------------------------------------------------------

TMP_DESKTOP="$TEMP_DIR/$SAFE_NAME.desktop"

ESCAPED_NAME="$(desktop_escape "$APP_NAME")"
ESCAPED_COMMENT="$(desktop_escape "$COMMENT")"

{
    echo "[Desktop Entry]"
    echo "Version=1.0"
    echo "Type=Application"
    echo "Name=$ESCAPED_NAME"
    echo "Comment=$ESCAPED_COMMENT"

    printf 'Exec="%s" %%U\n' "$APPIMAGE"

    echo "Icon=$MAIN_ICON"
    echo "Terminal=false"
    echo "Categories=$CATEGORY;"
    echo "StartupNotify=true"

    if [[ -n "$EMBEDDED_MIME" ]]; then
        echo "MimeType=$EMBEDDED_MIME"
    fi

} > "$TMP_DESKTOP"

chmod 644 "$TMP_DESKTOP"

# ------------------------------------------------------------
# Install launcher
# ------------------------------------------------------------

if [[ "$SCOPE" == "system" ]]; then

    printf '%s\n' "$SUDO_PASSWORD" \
        | sudo -S -p '' install \
            -m 644 \
            "$TMP_DESKTOP" \
            "$DESKTOP_FILE" ||
                error_exit "Unable to install launcher:

$DESKTOP_FILE"

else

    install \
        -m 644 \
        "$TMP_DESKTOP" \
        "$DESKTOP_FILE" ||
            error_exit "Unable to install launcher:

$DESKTOP_FILE"

fi

[[ -f "$DESKTOP_FILE" ]] ||
    error_exit "Launcher was not created:

$DESKTOP_FILE"

# ------------------------------------------------------------
# Refresh desktop menu databases
# ------------------------------------------------------------

refresh_desktop_menus "$DESKTOP_DIR"

# ------------------------------------------------------------
# Finish
# ------------------------------------------------------------

if [[ "$ICON_NUMBER" -gt 0 ]]; then

    ICON_TEXT="$ICON_NUMBER icon(s) extracted to:

$ICON_DIR"

else

    ICON_TEXT="Generic application icon used."

fi

kdialog \
    --title "$TITLE" \
    --msgbox \
    "Shortcut created successfully.

Application:
$APP_NAME

AppImage:
$APPIMAGE

Launcher:
$DESKTOP_FILE

Category:
$CATEGORY

$ICON_TEXT

The application should now appear in the KDE Application Launcher."

exit 0
