"""Open the Windows UI against demo data, render every page and (on Windows) save screenshots.

Usage: python tests/windows_gui_smoke.py <out-dir>
Expects the CSV_* variables printed by tests/make_demo.py in the environment.
Fails if any page raises while rendering.
"""
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "app"))
sys.path.insert(0, str(ROOT))
os.environ.setdefault("CSV_ALLOW_NON_WINDOWS", "1")
import windows_app as w  # noqa: E402

out = Path(sys.argv[1] if len(sys.argv) > 1 else "screenshots")
out.mkdir(parents=True, exist_ok=True)
w.VAULT_DIR, w.CORE_EXE = w.bootstrap()
root = w.tk.Tk()
errors = []
root.report_callback_exception = lambda exc, val, tb: errors.append(repr(val))
app = w.App(root)
deadline = time.time() + 30
while not app.status and time.time() < deadline:
    root.update()
    time.sleep(0.1)
assert app.status, "status never loaded"
print("accounts:", len(app.accounts()))
assert len(app.accounts()) >= 3, "demo accounts missing"

try:
    from PIL import ImageGrab
except ImportError:
    ImageGrab = None

for page in ["overview", "usage", "chats", "guide", "settings"]:
    app.go(page)
    for _ in range(10):
        root.update()
        time.sleep(0.05)
    if ImageGrab and os.name == "nt":
        x, y = root.winfo_rootx(), root.winfo_rooty()
        img = ImageGrab.grab(bbox=(x, y, x + root.winfo_width(), y + root.winfo_height()))
        img.save(out / f"{os.environ.get('CSV_LANG', 'zh')}-{page}.png")
    print("rendered", page)

root.destroy()
if errors:
    print("errors:", errors)
    sys.exit(1)
print("ok")
