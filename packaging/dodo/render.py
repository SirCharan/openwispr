# Regenerate: python3 render.py   (needs playwright + macOS sips + Google Chrome; fonts load from Google Fonts)
import pathlib
from playwright.sync_api import sync_playwright
import subprocess
d = pathlib.Path(__file__).parent
with sync_playwright() as p:
    b = p.chromium.launch(channel="chrome")
    for (w, h, name) in [(1200, 1200, "openwispr-product-1200.png"), (1600, 900, "openwispr-product-1600x900.png")]:
        pg = b.new_page(viewport={"width": w, "height": h}, device_scale_factor=2)
        pg.goto((d / "product-image.html").as_uri())
        pg.wait_for_function("document.fonts.ready.then(()=>true)")
        pg.evaluate("document.fonts.ready")
        out = d / name
        pg.screenshot(path=str(out))
        subprocess.run(["sips", "-z", str(h), str(w), str(out)], check=True, capture_output=True)
    b.close()
