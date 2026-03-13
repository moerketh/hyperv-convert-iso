#!/bin/bash
set -e

# Source os-release to get $ID, $ID_LIKE, $PRETTY_NAME inside chroot
. /etc/os-release

# Determine the package manager family
is_arch() { [ "$ID" = "arch" ] || [[ "${ID_LIKE:-}" =~ arch ]]; }
is_debian() { [ "$ID" = "debian" ] || [ "$ID" = "ubuntu" ] || [[ "${ID_LIKE:-}" =~ debian ]]; }
is_fedora() { [ "$ID" = "fedora" ] || [[ "${ID_LIKE:-}" =~ fedora ]]; }
is_suse() { [ "$ID" = "opensuse-tumbleweed" ] || [ "$ID" = "opensuse-leap" ] || [[ "${ID_LIKE:-}" =~ suse ]]; }

###############################################################################
# Skip if no X11/Xorg display server is installed (e.g. server/minimal images)
###############################################################################
if ! command -v Xorg >/dev/null 2>&1 && ! command -v startx >/dev/null 2>&1; then
  echo "XRDP_SKIPPED: No X11/Xorg display server found — xRDP requires a graphical session. Skipping."
  exit 0
fi

###############################################################################
# Install xRDP
###############################################################################
if is_arch; then
  # xrdp is not in the official Arch repos — build from source
  pacman -Syy --noconfirm
  pacman -S --noconfirm base-devel nasm xorg-server openssl pam libxrandr libxfixes
  _xrdp_build=$(mktemp -d)
  git clone --depth 1 https://github.com/neutrinolabs/xrdp.git "$_xrdp_build/xrdp"
  cd "$_xrdp_build/xrdp"
  ./bootstrap
  ./configure --enable-vsock
  make -j"$(nproc)"
  make install
  cd /
  rm -rf "$_xrdp_build"
  # Create the systemd units that the source build doesn't install
  cat > /etc/systemd/system/xrdp.service << 'XRDPUNIT'
[Unit]
Description=xrdp daemon
After=network.target xrdp-sesman.service
Requires=xrdp-sesman.service

[Service]
Type=forking
PIDFile=/var/run/xrdp/xrdp.pid
ExecStart=/usr/local/sbin/xrdp
ExecStop=/usr/local/sbin/xrdp --kill

[Install]
WantedBy=multi-user.target
XRDPUNIT
  cat > /etc/systemd/system/xrdp-sesman.service << 'SESUNIT'
[Unit]
Description=xrdp session manager
After=network.target

[Service]
Type=forking
PIDFile=/var/run/xrdp/xrdp-sesman.pid
ExecStart=/usr/local/sbin/xrdp-sesman
ExecStop=/usr/local/sbin/xrdp-sesman --kill

[Install]
WantedBy=multi-user.target
SESUNIT
elif is_debian; then
  apt-get update -y
  apt-get install -y xrdp
  adduser xrdp ssl-cert || true
elif is_fedora; then
  dnf install -y xrdp
elif is_suse; then
  zypper install -y xrdp
else
  echo "Unknown distribution: $ID (ID_LIKE: ${ID_LIKE:-none})"
  exit 1
fi

# Config paths differ between package installs (/etc/xrdp/) and source builds (/usr/local/etc/xrdp/)
if [ -f /etc/xrdp/xrdp.ini ]; then
  INI=/etc/xrdp/xrdp.ini
  SESMAN=/etc/xrdp/sesman.ini
elif [ -f /usr/local/etc/xrdp/xrdp.ini ]; then
  INI=/usr/local/etc/xrdp/xrdp.ini
  SESMAN=/usr/local/etc/xrdp/sesman.ini
else
  echo "ERROR: xrdp.ini not found — xRDP installation may have failed"
  exit 1
fi

###############################################################################
# Transport: vsock for Hyper-V Enhanced Session Mode
###############################################################################
sed -i '/^\[Globals\]/,/^\[/{s/^port=.*/port=vsock:\/\/-1:3389/}' "$INI"
sed -i '/^\[Globals\]/,/^\[/{s/^security_layer=.*/security_layer=rdp/}' "$INI"
sed -i '/^\[Globals\]/,/^\[/{s/^crypt_level=.*/crypt_level=none/}' "$INI"
sed -i '/^\[Sessions\]/,/^\[/{s/^X11DisplayOffset=.*/X11DisplayOffset=0/}' "$SESMAN"

###############################################################################
# Auto-select Xorg session (removes the session-type dropdown)
###############################################################################
sed -i '/^\[Globals\]/,/^\[/{s/^autorun=.*/autorun=Xorg/}' "$INI"

###############################################################################
# Login screen title — use distro pretty name
###############################################################################
sed -i '/^#*ls_title=/c\ls_title='"${PRETTY_NAME}" "$INI"

###############################################################################
# Pre-fill login username (passed via XRDP_USERNAME env var from KVP)
###############################################################################
if [ -n "${XRDP_USERNAME:-}" ]; then
    sed -i '/^#*ls_username=/c\ls_username='"${XRDP_USERNAME}" "$INI"
    echo "xRDP: pre-filled login username to '${XRDP_USERNAME}'"
fi

###############################################################################
# Login screen colours — clean light dialog on dark outer background
###############################################################################
# Outer window background (dark, behind the login dialog / wallpaper)
sed -i 's/^ls_top_window_bg_color=.*/ls_top_window_bg_color=171717/' "$INI"
# Dialog background (light for proper text contrast)
sed -i 's/^ls_bg_color=.*/ls_bg_color=f0f0f0/' "$INI"
# UI chrome colours
sed -i 's/^grey=.*/grey=e8e8e8/'       "$INI"
sed -i 's/^dark_grey=.*/dark_grey=d0d0d0/' "$INI"
sed -i 's/^blue=.*/blue=2777ff/'       "$INI"
sed -i 's/^dark_blue=.*/dark_blue=1a3a6a/' "$INI"
sed -i 's/^black=.*/black=2a2a2a/'     "$INI"
sed -i 's/^white=.*/white=ffffff/'     "$INI"

###############################################################################
# Login screen layout — roomy dialog with centred logo
###############################################################################
sed -i 's/^ls_width=.*/ls_width=400/'           "$INI"
sed -i 's/^ls_height=.*/ls_height=425/'         "$INI"
sed -i 's/^ls_logo_x_pos=.*/ls_logo_x_pos=26/' "$INI"
sed -i 's/^ls_logo_y_pos=.*/ls_logo_y_pos=30/' "$INI"
sed -i 's/^ls_label_x_pos=.*/ls_label_x_pos=30/'   "$INI"
sed -i 's/^ls_label_width=.*/ls_label_width=70/'    "$INI"
sed -i 's/^ls_input_x_pos=.*/ls_input_x_pos=120/'   "$INI"
sed -i 's/^ls_input_width=.*/ls_input_width=250/'    "$INI"
sed -i 's/^ls_input_y_pos=.*/ls_input_y_pos=250/'   "$INI"
sed -i 's/^ls_btn_ok_x_pos=.*/ls_btn_ok_x_pos=160/'       "$INI"
sed -i 's/^ls_btn_ok_y_pos=.*/ls_btn_ok_y_pos=385/'       "$INI"
sed -i 's/^ls_btn_ok_width=.*/ls_btn_ok_width=90/'        "$INI"
sed -i 's/^ls_btn_ok_height=.*/ls_btn_ok_height=30/'      "$INI"
sed -i 's/^ls_btn_cancel_x_pos=.*/ls_btn_cancel_x_pos=260/'   "$INI"
sed -i 's/^ls_btn_cancel_y_pos=.*/ls_btn_cancel_y_pos=385/'   "$INI"
sed -i 's/^ls_btn_cancel_width=.*/ls_btn_cancel_width=90/'    "$INI"
sed -i 's/^ls_btn_cancel_height=.*/ls_btn_cancel_height=30/'  "$INI"

###############################################################################
# Ensure distro logo is 24-bit BMP3 (xRDP rejects 32-bit BMPs silently)
###############################################################################
logo=$(grep '^ls_logo_filename=' "$INI" | cut -d= -f2)
if [ -n "$logo" ] && [ -f "$logo" ] && command -v convert &>/dev/null; then
  bpp=$(file "$logo" | grep -oP 'x \K\d+(?=,)')
  if [ "$bpp" != "24" ]; then
    convert "$logo" -background white -flatten -type TrueColor -depth 8 \
      -alpha off -define bmp:format=bmp3 "BMP3:${logo}.tmp" 2>/dev/null \
      && mv "${logo}.tmp" "$logo"
    echo "xRDP: Converted logo $logo from ${bpp}-bit to 24-bit"
  fi
fi

###############################################################################
# Login wallpaper — convert a distro background to BMP (best-effort)
###############################################################################
set_login_wallpaper() {
  local wallpaper=""
  # Prefer login-specific backgrounds, then named defaults, then first .jpg
  for f in \
    /usr/share/backgrounds/login.jpg \
    /usr/share/backgrounds/login.png \
    /usr/share/backgrounds/default.jpg \
    /usr/share/backgrounds/default.png \
    /usr/share/backgrounds/sddm/*.jpg; do
    if [ -f "$f" ]; then wallpaper="$f"; break; fi
  done
  if [ -z "$wallpaper" ]; then
    wallpaper=$(find /usr/share/backgrounds -maxdepth 1 -name '*.jpg' -type f 2>/dev/null | head -1)
  fi
  [ -z "$wallpaper" ] && return 0

  local bmp="/usr/share/xrdp/login-background.bmp"

  # Generate at 3840x2160 to cover any RDP session resolution (16:9 / 16:10)
  # xRDP requires 24-bit BMP3 — no alpha channel
  if command -v convert &>/dev/null; then
    convert "$wallpaper" -resize 3840x2160^ -gravity center -extent 3840x2160 \
      -type TrueColor -depth 8 -define bmp:format=bmp3 "BMP3:$bmp" 2>/dev/null
  elif command -v ffmpeg &>/dev/null; then
    ffmpeg -y -i "$wallpaper" \
      -vf "scale=3840:2160:force_original_aspect_ratio=increase,crop=3840:2160" \
      -pix_fmt bgr24 -update 1 "$bmp" 2>/dev/null
  elif python3 -c "from PIL import Image" 2>/dev/null; then
    python3 <<PYEOF
from PIL import Image
img = Image.open("$wallpaper").convert("RGB")
w, h = img.size
target = 3840 / 2160
if w / h > target:
    nw = int(h * target)
    img = img.crop(((w - nw) // 2, 0, (w + nw) // 2, h))
else:
    nh = int(w / target)
    img = img.crop((0, (h - nh) // 2, w, (h + nh) // 2))
img = img.resize((3840, 2160), Image.LANCZOS)
img.save("$bmp", "BMP")
PYEOF
  else
    return 0
  fi

  if [ -f "$bmp" ]; then
    sed -i "s|^#*ls_background_image=.*|ls_background_image=$bmp|" "$INI"
    echo "xRDP: Login background set from $wallpaper"
  fi
}
set_login_wallpaper

###############################################################################
# Remove extra session types so the dropdown disappears (keep only Xorg)
###############################################################################
sed -i '/^\[Xvnc\]/,$d' "$INI"

###############################################################################
# Session startup — auto-detect desktop environment, proper D-Bus
###############################################################################
XRDP_CONFDIR=$(dirname "$INI")
cat > "$XRDP_CONFDIR/startwm.sh" << 'STARTWM'
#!/bin/sh
# xrdp session — auto-detect desktop environment

if test -r /etc/profile; then
    . /etc/profile
fi
if test -r ~/.profile; then
    . ~/.profile
fi

# Ensure UTF-8 locale — xRDP's sesman starts sessions with LANG=C (ASCII),
# unlike LightDM/GDM which read /etc/default/locale via PAM. Qt 5/6 (used by
# KDE Plasma) requires UTF-8 for string handling, D-Bus messages, icon theme
# names, config paths, and font rendering. Without it, kwin_x11 starts but
# plasmashell fails to initialize — resulting in a black screen with only a
# cursor. We detect the broken locale and upgrade to the best available UTF-8
# locale before any DE is launched.
if [ -z "$LANG" ] || [ "$LANG" = "C" ] || [ "$LANG" = "POSIX" ]; then
    if locale -a 2>/dev/null | grep -qi 'en_US.utf8'; then
        export LANG=en_US.UTF-8
    elif locale -a 2>/dev/null | grep -qi 'C.utf8'; then
        export LANG=C.UTF-8
    fi
fi
export LC_ALL="${LANG}"

# D-Bus session bus (required by KDE, GNOME and most modern DEs)
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ] && command -v dbus-launch >/dev/null 2>&1; then
    eval $(dbus-launch --sh-syntax --exit-with-session)
fi

# Detect installed desktop environment and start it
if [ -x /usr/bin/startplasma-x11 ]; then
    export XDG_SESSION_TYPE=x11
    export XDG_SESSION_DESKTOP=KDE
    export XDG_CURRENT_DESKTOP=KDE
    exec /usr/bin/startplasma-x11
elif [ -x /usr/bin/mate-session ]; then
    export XDG_CURRENT_DESKTOP=MATE
    exec /usr/bin/mate-session
elif [ -x /usr/bin/startxfce4 ]; then
    export XDG_CURRENT_DESKTOP=XFCE
    exec /usr/bin/startxfce4
elif [ -x /usr/bin/gnome-session ]; then
    export XDG_SESSION_TYPE=x11
    export XDG_CURRENT_DESKTOP=GNOME
    exec /usr/bin/gnome-session
elif [ -x /usr/bin/cinnamon-session ]; then
    export XDG_CURRENT_DESKTOP=X-Cinnamon
    exec /usr/bin/cinnamon-session
elif [ -x /usr/bin/startlxqt ]; then
    export XDG_CURRENT_DESKTOP=LXQt
    exec /usr/bin/startlxqt
elif [ -x /usr/bin/startlxde ]; then
    export XDG_CURRENT_DESKTOP=LXDE
    exec /usr/bin/startlxde
fi

# Fallback to system session manager
test -x /etc/X11/Xsession && exec /etc/X11/Xsession
exec /bin/sh /etc/X11/Xsession
STARTWM
chmod +x "$XRDP_CONFDIR/startwm.sh"

###############################################################################
# Enable services (start deferred to next boot)
###############################################################################
systemctl enable xrdp
systemctl enable xrdp-sesman

###############################################################################
# Disable display-manager autologin — xRDP Enhanced Session creates its own
# X11 session (display :1). If LightDM/GDM also auto-logs in the same user
# on display :0, KDE Plasma ends up with two sessions sharing one D-Bus user
# bus. When the user clicks "Reboot" from the xRDP desktop, plasma-shutdown
# kills Plasma components across BOTH displays, but systemd-logind refuses to
# reboot because the LightDM session is still active. Result: Plasma is dead
# on :1 (black screen with cursor) and the reboot never happens.
#
# Disabling autologin means display :0 sits at the greeter — the user's only
# active session is the xRDP one, reboot/shutdown works, and there's no
# cross-session D-Bus interference.
###############################################################################
if [ -f /etc/lightdm/lightdm.conf ]; then
    sed -i 's/^autologin-user=/#autologin-user=/' /etc/lightdm/lightdm.conf
    echo "xRDP: disabled LightDM autologin to avoid session conflicts"
fi

if [ -f /etc/gdm3/daemon.conf ]; then
    sed -i 's/^AutomaticLoginEnable=.*/AutomaticLoginEnable=false/' /etc/gdm3/daemon.conf
    echo "xRDP: disabled GDM autologin to avoid session conflicts"
fi

if [ -f /etc/sddm.conf ]; then
    sed -i '/^\[Autologin\]/,/^\[/{s/^User=.*/#User=/}' /etc/sddm.conf
    echo "xRDP: disabled SDDM autologin to avoid session conflicts"
fi