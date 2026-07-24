#!/usr/bin/env bash
# =============================================================================
# bCNC macOS .dmg Builder — with OpenCV camera support
#
# Prerequisites (install once):
#   xcode-select --install
#   brew install python@3.13 python-tk@3.13 create-dmg
#
# Usage:
#   chmod +x build_dmg.sh && ./build_dmg.sh
# =============================================================================

set -euo pipefail

APP_NAME="bCNC"
APP_VERSION="0.9.16"
BUNDLE_ID="com.bcnc.bCNC"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${SCRIPT_DIR}/venv_bcnc"
BUILD_DIR="${SCRIPT_DIR}/build"
DIST_DIR="${SCRIPT_DIR}/dist"
DMG_OUT="${SCRIPT_DIR}/${APP_NAME}-${APP_VERSION}-mac.dmg"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

echo -e "${BLUE}"
echo "╔══════════════════════════════════════════════════╗"
echo "║   bCNC macOS DMG Builder  v${APP_VERSION}               ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── 1. Platform ───────────────────────────────────────────────────────────────
[[ "$(uname)" == "Darwin" ]] || die "This script must be run on macOS."
ARCH="$(uname -m)"
info "Architecture: ${ARCH}"

# opencv-python-headless 5.x ships macOS 14.0+ wheels for x86_64, 13.0+ for arm64
if [[ "$ARCH" == "arm64" ]]; then
    MACOS_MIN="13.0"
else
    MACOS_MIN="14.0"
fi

# ── 2. Python ─────────────────────────────────────────────────────────────────
# A differently-arched Python earlier in $PATH (e.g. an Intel Homebrew still
# lingering on an Apple Silicon Mac) would otherwise get picked, producing a
# Rosetta-translated app — Tk 9.0's macOS menu code aborts when translated.
# So every candidate is checked for a native-arch match, not just the first
# one found; the native Homebrew prefix is searched first, then the rest of
# $PATH, and any wrong-arch hits are skipped rather than accepted.
if [[ "$ARCH" == "arm64" ]]; then
    NATIVE_PREFIX="/opt/homebrew"
else
    NATIVE_PREFIX="/usr/local"
fi

info "Locating a native ${ARCH} Python 3.11–3.14..."
IFS=':' read -ra PATH_DIRS <<< "$PATH"
SEARCH_DIRS=("${NATIVE_PREFIX}/bin" "${PATH_DIRS[@]}")

PYTHON=""
FOUND_WRONG_ARCH=""
for candidate in python3.13 python3.12 python3.14 python3.11; do
    for dir in "${SEARCH_DIRS[@]}"; do
        bin="${dir}/${candidate}"
        [[ -x "$bin" ]] || continue
        ver=$("$bin" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null) || continue
        major="${ver%%.*}"; minor="${ver##*.}"
        [[ "$major" -eq 3 && "$minor" -ge 11 && "$minor" -le 14 ]] || continue
        py_arch=$("$bin" -c "import platform; print(platform.machine())" 2>/dev/null)
        if [[ "$py_arch" == "$ARCH" ]]; then
            PYTHON="$bin"
            info "Using native Python: $PYTHON ($ver, ${py_arch})"
            break 2
        else
            FOUND_WRONG_ARCH="${bin} (${py_arch})"
        fi
    done
done

if [[ -z "$PYTHON" ]]; then
    extra=""
    [[ -n "$FOUND_WRONG_ARCH" ]] && extra="\n  Found ${FOUND_WRONG_ARCH} but it doesn't match this Mac's arch (${ARCH})."
    die "No native ${ARCH} Python 3.11–3.14 found.${extra}\n  Install: brew install python@3.13 python-tk@3.13\n  (native ${ARCH} Homebrew lives at ${NATIVE_PREFIX})"
fi
success "Python architecture OK (native ${ARCH})"

info "Checking tkinter..."
"$PYTHON" -c "import tkinter" 2>/dev/null \
    || die "tkinter missing.\n  Fix: brew install python-tk@3.13"
success "tkinter OK"

# ── 3. Homebrew tools ─────────────────────────────────────────────────────────
info "Checking Homebrew tools..."
command -v brew &>/dev/null || die "Homebrew not found: https://brew.sh"
command -v create-dmg &>/dev/null || { info "Installing create-dmg..."; brew install create-dmg; }
command -v iconutil &>/dev/null   || die "iconutil missing — run: xcode-select --install"
success "Tools OK"

# ── 4. Virtual environment ────────────────────────────────────────────────────
info "Creating virtual environment..."
rm -rf "$VENV_DIR"
"$PYTHON" -m venv "$VENV_DIR"
PIP="${VENV_DIR}/bin/pip"
PY="${VENV_DIR}/bin/python"
"$PIP" install --upgrade pip wheel setuptools -q

# ── 5. Install dependencies ───────────────────────────────────────────────────
info "Installing Python packages..."

# opencv-python-headless 5.x requires numpy>=2
"$PIP" install "numpy==2.4.6" -q

# OpenCV headless — ships VideoCapture (AVFoundation on macOS), no Qt conflicts
"$PIP" install "opencv-python-headless==5.0.0.93" -q

"$PIP" install \
    "Pillow>=11.0" \
    "pyserial>=3.5" \
    "svgelements>=1.9,<2.0" \
    "shxparser>=0.0.2" \
    "tkinter-gl>=1.1" \
    -q

"$PIP" install bcnc -q
"$PIP" install "pyinstaller==6.21.0" -q

success "All packages installed"

# ── 6. Locate bCNC ────────────────────────────────────────────────────────────
BCNC_PATH=$("$PY" -c "import bCNC, os; print(os.path.dirname(bCNC.__file__))")
info "bCNC path: ${BCNC_PATH}"

# ── 7. Patch Camera.py — threaded capture so UI never hangs ──────────────────
info "Patching Camera.py for non-blocking threaded capture..."
cat > "${BCNC_PATH}/Camera.py" << 'CAMERAEOF'
import threading
import Utils

try:
    import cv2 as cv
except ImportError:
    cv = None

try:
    import numpy as np
except ImportError:
    np = None

try:
    from PIL import Image, ImageTk
except ImportError:
    print("Unable to import Image, ImageTk from Pillow")
    cv = None


def hasOpenCV():
    return cv is not None


class Camera:
    def __init__(self, prefix=""):
        if cv is None:
            return
        self.prefix   = prefix
        self.idx      = Utils.getInt("Camera", prefix)
        self.props    = self._getCameraProperties(prefix)
        self.camera   = None
        self.image    = None
        self.frozen   = None
        self.imagetk  = None
        self.original = None
        self._lock    = threading.Lock()
        self._thread  = None
        self._running = False

    def _getCameraProperties(self, prefix):
        try:
            POSSIBLE_PROPERTIES = {
                "height":     (Utils.getInt,   cv.CAP_PROP_FRAME_HEIGHT),
                "width":      (Utils.getInt,   cv.CAP_PROP_FRAME_WIDTH),
                "fps":        (Utils.getInt,   cv.CAP_PROP_FPS),
                "codec":      (Utils.getStr,   cv.CAP_PROP_FOURCC),
                "brightness": (Utils.getInt,   cv.CAP_PROP_BRIGHTNESS),
                "contrast":   (Utils.getInt,   cv.CAP_PROP_CONTRAST),
                "saturation": (Utils.getInt,   cv.CAP_PROP_SATURATION),
                "hue":        (Utils.getInt,   cv.CAP_PROP_HUE),
                "gain":       (Utils.getInt,   cv.CAP_PROP_GAIN),
                "exposure":   (Utils.getInt,   cv.CAP_PROP_EXPOSURE),
            }
        except AttributeError:
            return {}
        UNSPECIFIED = object()
        result = {}
        for key, (fn, prop) in POSSIBLE_PROPERTIES.items():
            val = fn("Camera", "_".join([prefix, key]), default=UNSPECIFIED)
            if val is not UNSPECIFIED:
                result[prop] = val
        return result

    def isOn(self):
        if cv is None:
            return False
        return self.camera is not None and self.camera.isOpened()

    def start(self):
        if cv is None:
            return False
        self._running    = False
        open_event       = threading.Event()
        self._start_ok   = False

        def _capture_loop():
            cap = cv.VideoCapture(self.idx)
            for prop_id, prop_value in self.props.items():
                cap.set(prop_id, prop_value)
            if not cap.isOpened():
                open_event.set()
                return
            ok, frame = cap.read()
            if not ok:
                cap.release()
                open_event.set()
                return
            with self._lock:
                self.camera   = cap
                self.image    = frame
                self.original = frame
            self._start_ok = True
            self._running  = True
            open_event.set()
            # Continuous capture loop — runs entirely in background thread
            while self._running:
                ok, frame = cap.read()
                if not ok:
                    self._running = False
                    break
                frame = self._rotate90(frame)
                with self._lock:
                    self.original = frame
                    if self.frozen is not None:
                        self.image = cv.addWeighted(frame, 0.7, self.frozen, 0.3, 0.0)
                    else:
                        self.image = frame

        self._thread = threading.Thread(target=_capture_loop, daemon=True)
        self._thread.start()
        open_event.wait(timeout=5.0)
        if not self._start_ok:
            return False
        self.set()
        return True

    def stop(self):
        if cv is None:
            return
        self._running = False
        if self._thread:
            self._thread.join(timeout=2.0)
        with self._lock:
            if self.camera:
                self.camera.release()
                self.camera = None

    def set(self):
        self.angle    = Utils.getInt("Camera",   self.prefix + "_angle") // 90 % 4
        self.rotation = Utils.getFloat("Camera", self.prefix + "_rotation")
        self.xcenter  = Utils.getFloat("Camera", self.prefix + "_xcenter")
        self.ycenter  = Utils.getFloat("Camera", self.prefix + "_ycenter")

    def read(self):
        with self._lock:
            return self.image is not None

    def save(self, filename):
        with self._lock:
            if self.original is not None:
                cv.imwrite(filename, self.original)

    def jpg(self):
        with self._lock:
            if self.image is None:
                return None
            ok, jpg = cv.imencode(".jpg", self.image)
            return jpg if ok else None

    def _rotate90(self, image):
        if not hasattr(self, 'rotation'):
            return image
        if self.rotation > 0:
            rows, cols = image.shape[:2]
            m = cv.getRotationMatrix2D((cols / 2, rows / 2), self.rotation, 1)
            image = cv.warpAffine(image, m, (cols, rows), None,
                                   cv.INTER_LINEAR, cv.BORDER_CONSTANT, (255, 255, 255))
            t = np.float32([[1, 0, -self.xcenter], [0, 1, -self.ycenter]])
            image = cv.warpAffine(image, t, (cols, rows), None,
                                   cv.INTER_LINEAR, cv.BORDER_CONSTANT, (255, 255, 255))
            return image
        if self.angle == 1:
            return cv.transpose(cv.flip(image, 1))
        elif self.angle == 2:
            return cv.flip(image, -1)
        elif self.angle == 3:
            return cv.flip(cv.transpose(image), 1)
        return image

    def rotate90(self, image):
        return self._rotate90(image)

    def resize(self, factor, maxwidth, maxheight):
        if factor == 1.0:
            return
        with self._lock:
            if self.image is None:
                return
            h, w = self.image.shape[:2]
            wn, hn = int(w * factor), int(h * factor)
            if wn > maxwidth or hn > maxheight:
                wn = int(maxwidth / factor) // 2
                hn = int(maxheight / factor) // 2
                w2, h2 = w // 2, h // 2
                self.image = self.image[
                    max(h2-hn, 0):min(h2+hn, h-1),
                    max(w2-wn, 0):min(w2+wn, w-1)]
            try:
                self.image = cv.resize(self.image, (0, 0), fx=factor, fy=factor)
            except Exception:
                pass

    def canny(self, threshold1, threshold2):
        with self._lock:
            if self.image is None:
                return
            edge = cv.cvtColor(cv.Canny(self.image, threshold1, threshold2),
                                cv.COLOR_GRAY2BGR)
            self.image = cv.addWeighted(self.image, 0.9, edge, 0.5, 0.0)

    def freeze(self, f):
        with self._lock:
            self.frozen = self.image.copy() if f and self.image is not None else None

    def getCenterTemplate(self, r):
        with self._lock:
            if self.original is None:
                return None
            h, w = self.original.shape[:-1]
            w2, h2 = w // 2, h // 2
            return self.original[h2-r:h2+r, w2-r:w2+r]

    def matchTemplate(self, template):
        with self._lock:
            if self.original is None:
                return 0, 0
            method = cv.TM_CCOEFF_NORMED
            res = cv.matchTemplate(self.original, template, method)
            _, _, _, max_loc = cv.minMaxLoc(res)
            h, w = self.original.shape[:-1]
            r = template.shape[1] // 2
            return w // 2 - r - max_loc[0], h // 2 - r - max_loc[1]

    def toTk(self):
        with self._lock:
            if self.image is None:
                return None
            self.imagetk = ImageTk.PhotoImage(
                image=Image.fromarray(
                    cv.cvtColor(self.image, cv.COLOR_BGR2RGB), "RGB"))
            return self.imagetk
CAMERAEOF
success "Camera.py patched"

# ── 8. Generate icon ──────────────────────────────────────────────────────────
info "Generating icon..."
mkdir -p "${BUILD_DIR}"
ICONSET_DIR="${BUILD_DIR}/bCNC.iconset"
mkdir -p "$ICONSET_DIR"
SRC_ICON="${BCNC_PATH}/bCNC.png"

for size in 16 32 64 128 256 512; do
    "$PY" -c "
from PIL import Image
img = Image.open('${SRC_ICON}').convert('RGBA').resize((${size}, ${size}), Image.LANCZOS)
img.save('${ICONSET_DIR}/icon_${size}x${size}.png')
img2 = Image.open('${SRC_ICON}').convert('RGBA').resize((${size}*2, ${size}*2), Image.LANCZOS)
img2.save('${ICONSET_DIR}/icon_${size}x${size}@2x.png')
"
done
iconutil -c icns "${ICONSET_DIR}" -o "${BUILD_DIR}/bCNC.icns"
success "Icon OK"

# ── 9. Write launcher ─────────────────────────────────────────────────────────
info "Writing launcher..."
cat > "${SCRIPT_DIR}/bcnc_launcher.py" << 'PYEOF'
import os, sys, builtins

def _bundle_resources():
    if hasattr(sys, '_MEIPASS'):
        # _MEIPASS = .app/Contents/MacOS — step up to Contents, into Resources
        return os.path.join(os.path.dirname(sys._MEIPASS), 'Resources')
    return os.path.abspath(os.path.dirname(__file__))

resources = _bundle_resources()
bcnc_base = os.path.join(resources, 'bCNC')

for sub in ('', 'lib', 'plugins', 'controllers'):
    p = os.path.join(bcnc_base, sub)
    if p not in sys.path:
        sys.path.insert(0, p)

# Add cv2 — PyInstaller places it in Resources/cv2
cv2_path = os.path.join(resources, 'cv2')
if os.path.isdir(cv2_path) and cv2_path not in sys.path:
    sys.path.insert(0, cv2_path)

# Install no-op _() before any bCNC module loads — bFileDialog uses it at
# class-definition time before Utils.initTranslator() has run
builtins._ = lambda x: x

# Tcl/Tk 9.0 removed the legacy "trace variable/vdelete/vinfo" Tcl commands,
# keeping only "trace add/remove/info". bCNC's CNCCanvas.py (and possibly
# other modules) still call the deprecated tkinter Variable.trace()/
# trace_variable() methods, which issue the old Tcl syntax and now raise
# TclError: bad option "variable". Redirect them to the modern trace_add()/
# trace_remove()/trace_info(), which take the same callback signature.
import tkinter

_TRACE_MODE_TO_NEW = {"r": "read", "w": "write", "u": "unset"}
_TRACE_MODE_TO_OLD = {v: k for k, v in _TRACE_MODE_TO_NEW.items()}

def _trace_variable_compat(self, mode, callback):
    return self.trace_add(_TRACE_MODE_TO_NEW.get(mode, mode), callback)

def _trace_compat(self, mode, callback):
    return _trace_variable_compat(self, mode, callback)

def _trace_vdelete_compat(self, mode, cbname):
    self.trace_remove(_TRACE_MODE_TO_NEW.get(mode, mode), cbname)

def _trace_vinfo_compat(self):
    return [(_TRACE_MODE_TO_OLD.get(m[0], m[0]) if len(m) == 1 else m, cb)
            for m, cb in self.trace_info()]

tkinter.Variable.trace_variable = _trace_variable_compat
tkinter.Variable.trace = _trace_compat
tkinter.Variable.trace_vdelete = _trace_vdelete_compat
tkinter.Variable.trace_vinfo = _trace_vinfo_compat

# Patch Utils.prgpath before bCNC reads it — it sets prgpath = dirname(__file__)
# at import time which resolves to MacOS/, but assets live in Resources/bCNC/
import Utils
Utils.prgpath   = bcnc_base
Utils.iniSystem = os.path.join(bcnc_base, 'bCNC.ini')

# Prefer AVFoundation for camera on macOS
os.environ.setdefault('OPENCV_VIDEOIO_PRIORITY_AVFOUNDATION', '1')

from bCNC.__main__ import main
sys.exit(main())
PYEOF
success "Launcher written"

# ── 10. Write entitlements ────────────────────────────────────────────────────
info "Writing entitlements..."
cat > "${SCRIPT_DIR}/entitlements.plist" << 'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.camera</key>
    <true/>
    <key>com.apple.security.device.usb</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
    <key>com.apple.security.network.server</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.app-sandbox</key>
    <false/>
</dict>
</plist>
PLISTEOF
success "Entitlements written"

# ── 11. Write PyInstaller hooks ───────────────────────────────────────────────
info "Writing hooks..."
mkdir -p "${SCRIPT_DIR}/hooks"

cat > "${SCRIPT_DIR}/hooks/hook-bCNC.py" << 'HOOKEOF'
from PyInstaller.utils.hooks import collect_data_files, collect_submodules
datas = collect_data_files('bCNC', includes=['**/*'])
hiddenimports = collect_submodules('bCNC')
HOOKEOF

cat > "${SCRIPT_DIR}/hooks/hook-cv2.py" << 'HOOKEOF'
from PyInstaller.utils.hooks import collect_dynamic_libs, collect_data_files
binaries = collect_dynamic_libs('cv2')
datas    = collect_data_files('cv2')
HOOKEOF
success "Hooks written"

# ── 12. Write PyInstaller spec ────────────────────────────────────────────────
info "Writing PyInstaller spec..."
cat > "${BUILD_DIR}/bCNC.spec" << SPECEOF
# -*- mode: python ; coding: utf-8 -*-
import os
from PyInstaller.utils.hooks import collect_data_files, collect_submodules

bcnc_path = "${BCNC_PATH}"

bcnc_datas = [
    (os.path.join(bcnc_path, 'icons'),       'bCNC/icons'),
    (os.path.join(bcnc_path, 'images'),      'bCNC/images'),
    (os.path.join(bcnc_path, 'plugins'),     'bCNC/plugins'),
    (os.path.join(bcnc_path, 'pendant'),     'bCNC/pendant'),
    (os.path.join(bcnc_path, 'controllers'), 'bCNC/controllers'),
    (os.path.join(bcnc_path, 'locales'),     'bCNC/locales'),
    (os.path.join(bcnc_path, 'lib'),         'bCNC/lib'),
    (os.path.join(bcnc_path, 'bCNC.ini'),    'bCNC'),
    (os.path.join(bcnc_path, 'bCNC.png'),    'bCNC'),
    (os.path.join(bcnc_path, 'bCNC.xbm'),    'bCNC'),
]

extra_datas = collect_data_files('svgelements') + collect_data_files('shxparser')

hidden = [
    'bCNC.controllers', 'bCNC.plugins', 'bCNC.lib',
    'tkinter', 'tkinter.ttk', 'tkinter.messagebox',
    'tkinter.filedialog', 'tkinter.font', 'tkinter.scrolledtext',
    '_tkinter',
    'cv2',
    'serial', 'serial.tools', 'serial.tools.list_ports',
    'serial.tools.list_ports_posix',
    'PIL', 'PIL.Image', 'PIL.ImageTk', 'PIL.FontFile',
    'PIL.BmpImagePlugin', 'PIL.PngImagePlugin',
    'PIL.JpegImagePlugin', 'PIL.GifImagePlugin', 'PIL.ImageFont',
    'numpy', 'numpy.core',
    'configparser', 'queue', 'threading', 'socket', 'http.server',
] + collect_submodules('bCNC') + collect_submodules('svgelements') + collect_submodules('shxparser')

a = Analysis(
    ['${SCRIPT_DIR}/bcnc_launcher.py'],
    pathex=['${SCRIPT_DIR}', bcnc_path],
    binaries=[],
    datas=bcnc_datas + extra_datas,
    hiddenimports=hidden,
    hookspath=['${SCRIPT_DIR}/hooks'],
    runtime_hooks=[],
    excludes=[
        'matplotlib', 'scipy', 'pandas', 'IPython',
        'PyQt5', 'PyQt6', 'PySide2', 'PySide6', 'wx',
        'pytest', 'setuptools', 'pip',
    ],
    noarchive=False,
    optimize=1,
)

pyz = PYZ(a.pure)

exe = EXE(
    pyz, a.scripts, [],
    exclude_binaries=True,
    name='bCNC',
    debug=False,
    strip=False,
    upx=False,
    console=False,
    argv_emulation=True,
    icon='${BUILD_DIR}/bCNC.icns',
    entitlements_file='${SCRIPT_DIR}/entitlements.plist',
)

coll = COLLECT(exe, a.binaries, a.datas, strip=False, upx=False, name='bCNC')

app = BUNDLE(
    coll,
    name='bCNC.app',
    icon='${BUILD_DIR}/bCNC.icns',
    bundle_identifier='${BUNDLE_ID}',
    version='${APP_VERSION}',
    info_plist={
        'CFBundleName': 'bCNC',
        'CFBundleDisplayName': 'bCNC',
        'CFBundleVersion': '${APP_VERSION}',
        'CFBundleShortVersionString': '${APP_VERSION}',
        'CFBundleIdentifier': '${BUNDLE_ID}',
        'CFBundleExecutable': 'bCNC',
        'CFBundlePackageType': 'APPL',
        'NSHighResolutionCapable': True,
        'NSCameraUsageDescription': 'bCNC uses the camera for workpiece alignment via the Camera module.',
        'LSMinimumSystemVersion': '${MACOS_MIN}',
        'NSPrincipalClass': 'NSApplication',
        'NSDocumentTypes': [{
            'CFBundleTypeName': 'GCode File',
            'CFBundleTypeRole': 'Editor',
            'CFBundleTypeExtensions': ['nc', 'gcode', 'cnc', 'tap', 'ngc'],
        }],
    },
)
SPECEOF
success "Spec written"

# ── 13. Run PyInstaller ───────────────────────────────────────────────────────
info "Running PyInstaller (1–3 minutes)..."
"${VENV_DIR}/bin/pyinstaller" \
    --clean --noconfirm \
    --distpath "${DIST_DIR}" \
    --workpath "${BUILD_DIR}/work" \
    "${BUILD_DIR}/bCNC.spec"

APP_BUNDLE="${DIST_DIR}/bCNC.app"
[[ -d "$APP_BUNDLE" ]] || die "bCNC.app not produced — check output above."
success "bCNC.app built"

# ── 14. Ad-hoc code sign ──────────────────────────────────────────────────────
# On arm64, macOS refuses to exec a binary without a valid signature at all —
# an app that fails to sign here will "flash and vanish" with no error dialog
# and no crash log, since it's killed by the kernel before main() ever runs.
# So a signing failure is fatal, not a warning to skip past.
info "Code signing (ad-hoc)..."
codesign --deep --force --sign - \
    --entitlements "${SCRIPT_DIR}/entitlements.plist" \
    --options runtime \
    "${APP_BUNDLE}" || die "codesign failed — the app will not launch without a valid signature (especially on arm64)."

info "Verifying code signature..."
codesign --verify --deep --strict "${APP_BUNDLE}" \
    || die "codesign verification failed after signing — the app will not launch."
success "Signed and verified"

# ── 15. Build DMG ─────────────────────────────────────────────────────────────
info "Building DMG..."
DMG_STAGING="${BUILD_DIR}/dmg_staging"
rm -rf "$DMG_STAGING" && mkdir -p "$DMG_STAGING"
cp -R "${APP_BUNDLE}" "${DMG_STAGING}/"
ln -s /Applications "${DMG_STAGING}/Applications"

rm -f "$DMG_OUT"
create-dmg \
    --volname "${APP_NAME} ${APP_VERSION}" \
    --volicon "${BUILD_DIR}/bCNC.icns" \
    --window-pos 200 120 \
    --window-size 660 420 \
    --icon-size 100 \
    --icon "bCNC.app" 160 185 \
    --hide-extension "bCNC.app" \
    --app-drop-link 500 185 \
    --no-internet-enable \
    "$DMG_OUT" \
    "$DMG_STAGING"

success "DMG created: ${DMG_OUT}  ($(du -sh "$DMG_OUT" | cut -f1))"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗"
echo    "║   Build complete!                                ║"
echo -e "╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Output: ${DMG_OUT}"
echo ""
echo -e "${YELLOW}First launch:${NC}"
echo "  1. Open the DMG and drag bCNC.app → Applications"
echo "  2. Right-click bCNC.app → Open  (bypasses Gatekeeper, once only)"
echo "  3. Allow camera access when prompted"
echo ""
