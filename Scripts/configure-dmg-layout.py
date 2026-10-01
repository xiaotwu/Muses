#!/usr/bin/env python3
"""Write Finder layout without scripting or changing the user's Finder preferences."""
import sys
from pathlib import Path
from ds_store import DSStore
from mac_alias import Alias

root = Path(sys.argv[1]).resolve()
background = root / ".background" / "installer.png"
assert background.is_file() and (root / "Muses.app").is_dir()
with DSStore.open(str(root / ".DS_Store"), "w+") as store:
    store["."]["vSrn"] = ("long", 1)
    store["."]["icvl"] = ("type", b"icnv")
    store["."]["bwsp"] = {
        "WindowBounds": "{{200, 180}, {700, 460}}",
        "ShowToolbar": False, "ShowStatusBar": False, "ShowPathbar": False,
        "ShowSidebar": False, "ContainerShowSidebar": False,
        "ShowTabView": False, "PreviewPaneVisibility": False,
    }
    store["."]["icvp"] = {
        "viewOptionsVersion": 1, "backgroundType": 2,
        "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
        "backgroundImageAlias": Alias.for_file(str(background)).to_bytes(),
        "iconSize": 96.0, "textSize": 10.0, "labelOnBottom": True,
        "arrangeBy": "none", "showIconPreview": True, "showItemInfo": False,
        "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 100.0,
        "scrollPositionX": 0.0, "scrollPositionY": 0.0,
    }
    for hidden in [".background", ".fseventsd", ".Trashes"]:
        store[hidden]["Iloc"] = (1200, 1200)
    store["Muses.app"]["Iloc"] = (220, 237)
    store["Applications"]["Iloc"] = (480, 237)
