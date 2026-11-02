"""Genera las capturas de App Store de Wizard Cat Reader con el mismo marco que Wizard Cat Notes.

Uso:  python make.py
Lee raw/NN.png (capturas crudas del iPhone, nombradas 01.png a 06.png en el orden de shots.json) y shots.json; escribe en/NN-en.png y es/NN-es.png
a 1206x2622 (tamaño iPhone 17 Pro). Requiere: pip install playwright pillow && playwright install chromium
"""
import base64
import json
import pathlib
import sys

from playwright.sync_api import sync_playwright

HERE = pathlib.Path(__file__).resolve().parent
W, H = 1206, 2622


def data_uri(path, mime="image/png"):
    return f"data:{mime};base64," + base64.b64encode(pathlib.Path(path).read_bytes()).decode()


FONTS = f"""
@font-face {{ font-family: Gloock; src: url({data_uri(HERE/'fonts/gloock-latin-400-normal.woff2','font/woff2')}) format('woff2'); }}
@font-face {{ font-family: Atkinson; src: url({data_uri(HERE/'fonts/atkinson-hyperlegible-latin-400-normal.woff2','font/woff2')}) format('woff2'); }}
"""

THEMES = {
    "light": dict(bg="#F4EFE4", title="#1C1626", sub="#625A6C", bezel="#1C1822",
                  seal_ink="#2A2430", seal_bg="#F4EFE4", cat_op=".10", cat_blend="multiply"),
    "dark": dict(bg="#15111E", title="#F3EEE4", sub="#B4A9C9", bezel="#3A3346",
                 seal_ink="#E9E2D3", seal_bg="#221C2C", cat_op=".6", cat_blend="multiply"),
}


def seal_svg(t, icon, label):
    # Sello circular: anillo doble, "WIZARD CAT" arriba, nombre de la app abajo, gato al centro.
    return f"""
<svg viewBox="0 0 200 200" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <path id="top" d="M 35 100 A 65 65 0 0 1 165 100"/>
    <path id="bot" d="M 18 100 A 82 82 0 0 0 182 100"/>
    <clipPath id="c"><circle cx="100" cy="100" r="54"/></clipPath>
    <filter id="ink"><feColorMatrix type="saturate" values="0"/></filter>
  </defs>
  <circle cx="100" cy="100" r="96" fill="{t['seal_bg']}" stroke="{t['seal_ink']}" stroke-width="5"/>
  <circle cx="100" cy="100" r="89" fill="none" stroke="{t['seal_ink']}" stroke-width="1.6"/>
  <circle cx="100" cy="100" r="56" fill="#F4EFE4" stroke="{t['seal_ink']}" stroke-width="2.2"/>
  <g clip-path="url(#c)">
    <image href="{icon}" x="-14" y="10" width="270" height="270" filter="url(#ink)"/>
  </g>
  <text font-family="Gloock" font-size="21" fill="{t['seal_ink']}" letter-spacing="2" text-anchor="middle">
    <textPath href="#top" startOffset="50%">WIZARD CAT</textPath></text>
  <text font-family="Gloock" font-size="20" fill="{t['seal_ink']}" letter-spacing="3" text-anchor="middle">
    <textPath href="#bot" startOffset="50%">{label}</textPath></text>
  <circle cx="26" cy="100" r="3" fill="{t['seal_ink']}"/><circle cx="174" cy="100" r="3" fill="{t['seal_ink']}"/>
</svg>"""


def page(shot, lang, label, icon):
    t = THEMES[shot["theme"]]
    txt = shot[lang]
    screen = data_uri(HERE / "raw" / shot["file"])
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>
{FONTS}
* {{ margin:0; box-sizing:border-box; }}
html,body {{ width:{W}px; height:{H}px; overflow:hidden; background:{t['bg']}; }}
.seal {{ position:absolute; left:{W//2-60}px; top:92px; width:120px; height:120px; }}
.head {{ position:absolute; left:110px; right:110px; top:256px; height:370px; display:flex; flex-direction:column; align-items:center; text-align:center; }}
h1 {{ font:400 118px/1.0 Gloock; letter-spacing:-.025em; color:{t['title']}; text-wrap:balance; }}
p {{ margin-top:14px; font:400 47px/1.3 Atkinson; color:{t['sub']}; text-wrap:balance; max-width:880px; }}
.cat {{ position:absolute; left:780px; top:2040px; width:560px; opacity:{t['cat_op']}; mix-blend-mode:{t['cat_blend']}; filter:grayscale(1) blur(1px); }}
.phone {{ position:absolute; left:162px; top:645px; width:882px; height:1878px; border-radius:118px; background:{t['bezel']};
          padding:16px; box-shadow:0 40px 80px -30px rgba(20,14,30,.45), 0 12px 30px -12px rgba(20,14,30,.25); }}
.screen {{ width:850px; height:1846px; border-radius:102px; overflow:hidden; background:#000; }}
.screen img {{ width:100%; height:100%; object-fit:cover; object-position:top; display:block; }}
</style></head><body>
<img class="cat" src="{icon}">
<div class="seal">{seal_svg(t, icon, label)}</div>
<div class="head"><h1>{txt['title']}</h1><p>{txt['subtitle']}</p></div>
<div class="phone"><div class="screen"><img src="{screen}"></div></div>
</body></html>"""


def main():
    cfg = json.loads((HERE / "shots.json").read_text(encoding="utf-8"))
    icon_path = HERE / "icon.png"
    if not icon_path.exists():
        icon_path = HERE.parents[1] / "iosApp/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
    icon = data_uri(icon_path)
    only = sys.argv[1:]
    with sync_playwright() as p:
        b = p.chromium.launch()
        pg = b.new_page(viewport={"width": W, "height": H}, device_scale_factor=1)
        for i, shot in enumerate(cfg["shots"], 1):
            if not (HERE / "raw" / shot["file"]).exists():
                print("falta raw/" + shot["file"]); continue
            for lang in ("en", "es"):
                if only and lang not in only: continue
                pg.set_content(page(shot, lang, cfg["app"], icon))
                pg.evaluate("document.fonts.ready")
                # Si el título pasa de 2 líneas, achica la letra hasta que quepa.
                pg.evaluate("""() => { const h = document.querySelector('h1'); let s = 118;
                    while (h.getBoundingClientRect().height > s * 2.05 && s > 80) { s -= 4; h.style.fontSize = s + 'px'; } }""")
                pg.wait_for_timeout(150)
                out = HERE / lang / f"{i:02d}-{lang}.png"
                out.parent.mkdir(exist_ok=True)
                pg.screenshot(path=str(out))
                print("ok", out.relative_to(HERE))
        b.close()


if __name__ == "__main__":
    main()
