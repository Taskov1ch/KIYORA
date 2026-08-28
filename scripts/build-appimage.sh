#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="${APPIMAGE_BUILD_DIR:-$project_root/build-appimage}"
meson_build_dir="$build_root/meson"
appdir="$build_root/AppDir"
tools_dir="$build_root/tools"
dist_dir="${APPIMAGE_DIST_DIR:-$project_root/dist}"
app_id="io.github.Taskov1ch.KIYORA"

case "$(uname -m)" in
    x86_64)
        appimage_arch="x86_64"
        ;;
    *)
        printf 'AppImage builds currently support x86_64 only.\n' >&2
        exit 1
        ;;
esac

required_commands=(
    curl
    file
    find
    meson
    ninja
    patchelf
    pkg-config
    sed
    sha256sum
)
missing_commands=()
for required_command in "${required_commands[@]}"; do
    if ! command -v "$required_command" >/dev/null; then
        missing_commands+=("$required_command")
    fi
done
if ((${#missing_commands[@]})); then
    printf 'Missing AppImage build tools: %s\n' "${missing_commands[*]}" >&2
    exit 1
fi

linuxdeploy_url="https://github.com/linuxdeploy/linuxdeploy/releases/download/1-alpha-20251107-1/linuxdeploy-x86_64.AppImage"
linuxdeploy_sha256="c20cd71e3a4e3b80c3483cef793cda3f4e990aca14014d23c544ca3ce1270b4d"
gtk_plugin_url="https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/7a3fbc31a9e5075073ff8790f26effbac5f84453/linuxdeploy-plugin-gtk.sh"
gtk_plugin_sha256="b0f4cbc684a0103a9651f0955b635eaea0096b3a66c0f5a2c2aa337960375171"
gstreamer_plugin_url="https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gstreamer/2a2e67491c32995a3f279ad0ecbe77abd512b42a/linuxdeploy-plugin-gstreamer.sh"
gstreamer_plugin_sha256="c107b49d84edbffc6ab226ed1007e0626a4f7aa2c3a36b7782bef62351d49e94"

download_tool() {
    local url="$1"
    local destination="$2"
    local checksum="$3"

    if [[ ! -f "$destination" ]] || ! printf '%s  %s\n' "$checksum" "$destination" | sha256sum --check --status; then
        curl --fail --location --retry 3 --output "$destination" "$url"
    fi
    printf '%s  %s\n' "$checksum" "$destination" | sha256sum --check --status
    chmod +x "$destination"
}

mkdir -p "$build_root" "$tools_dir" "$dist_dir" "$appdir"
find "$appdir" -mindepth 1 -delete

if [[ -f "$meson_build_dir/meson-private/coredata.dat" ]]; then
    meson setup "$meson_build_dir" "$project_root" \
        --reconfigure \
        --prefix=/usr \
        --buildtype=release
else
    meson setup "$meson_build_dir" "$project_root" \
        --prefix=/usr \
        --buildtype=release
fi

meson compile -C "$meson_build_dir"
meson test -C "$meson_build_dir" --print-errorlogs
DESTDIR="$appdir" meson install -C "$meson_build_dir"

# Desktop activation cannot use an external D-Bus service from a portable image.
sed -i 's/^DBusActivatable=true$/DBusActivatable=false/' \
    "$appdir/usr/share/applications/$app_id.desktop"

linuxdeploy="$tools_dir/linuxdeploy-$appimage_arch.AppImage"
# Keep the pristine cache outside linuxdeploy's plugin filename pattern.
gtk_plugin_upstream="$tools_dir/upstream-gtk-plugin.sh"
gtk_plugin="$tools_dir/linuxdeploy-plugin-gtk.sh"
gstreamer_plugin="$tools_dir/linuxdeploy-plugin-gstreamer.sh"
download_tool "$linuxdeploy_url" "$linuxdeploy" "$linuxdeploy_sha256"
download_tool "$gtk_plugin_url" "$gtk_plugin_upstream" "$gtk_plugin_sha256"
download_tool "$gstreamer_plugin_url" "$gstreamer_plugin" "$gstreamer_plugin_sha256"

# GTK 4 can be built without a separate gtk-4.0 modules directory. The
# upstream plugin treats the directory as mandatory, so make that copy
# conditional while keeping the downloaded, checksum-verified source intact.
cp "$gtk_plugin_upstream" "$gtk_plugin"
sed -i '/^        copy_lib_tree "$gtk4_libdir" "$APPDIR\/"$/c\
        if [[ -d "$gtk4_libdir" ]]; then\
            copy_lib_tree "$gtk4_libdir" "$APPDIR/"\
        fi' "$gtk_plugin"
chmod +x "$gtk_plugin"

if [[ -z "${VERSION:-}" ]]; then
    VERSION="$(meson introspect --projectinfo "$meson_build_dir" \
        | sed -n 's/.*"version": "\([^"]*\)".*/\1/p')"
fi
if [[ -z "$VERSION" ]]; then
    printf 'Could not determine the project version.\n' >&2
    exit 1
fi

output="$dist_dir/KIYORA-$VERSION-$appimage_arch.AppImage"
if [[ -e "$output" ]]; then
    unlink "$output"
fi

export APPIMAGE_EXTRACT_AND_RUN=1
export DEPLOY_GTK_VERSION=4
export LDAI_OUTPUT="$output"
export LINUXDEPLOY_OUTPUT_VERSION="$VERSION"
# linuxdeploy ships its own binutils, which cannot strip newer ELF files that
# contain SHT_RELR sections. The libraries are compressed in the AppImage
# anyway, so skipping this optional step avoids strip failures on newer hosts.
export NO_STRIP=1

# Prefer pkg-config over distro-specific paths. This covers Debian multiarch as
# well as distributions such as Arch and Fedora.
export GSTREAMER_PLUGINS_DIR="${GSTREAMER_PLUGINS_DIR:-$(pkg-config --variable=pluginsdir gstreamer-1.0)}"
export GSTREAMER_HELPERS_DIR="${GSTREAMER_HELPERS_DIR:-$(pkg-config --variable=pluginscannerdir gstreamer-1.0)}"

"$linuxdeploy" \
    --appdir "$appdir" \
    --plugin gtk \
    --plugin gstreamer

# Libadwaita provides its own stylesheet and color-scheme handling. Forcing
# GTK_THEME makes GTK load the legacy Adwaita theme on top of it, which changes
# button shapes, spacing and window controls in the AppImage. Also prefer the
# user's native Wayland/X11 backend instead of forcing X11.
gtk_hook="$appdir/apprun-hooks/linuxdeploy-plugin-gtk.sh"
sed -i \
    -e '/^COLOR_SCHEME=/,/^APPIMAGE_GTK_THEME=/d' \
    -e 's/^export GTK_THEME=.*/unset GTK_THEME/' \
    -e '/^export GDK_BACKEND=x11/d' \
    "$gtk_hook"

"$linuxdeploy" \
    --appdir "$appdir" \
    --output appimage

test -x "$output"
printf 'Built %s\n' "$output"
