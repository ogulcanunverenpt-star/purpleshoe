"""Restores Openworld's assets into openworld/ so the world runs fully offline (no CDN at runtime).

Run once:  python openworld/tools/fetch_assets.py
Then:      python openworld/tools/gen_world.py   (writes openworld/world.json)
"""
import re
import shutil
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CDN = "https://preview.myapping.com"
ASSETS = CDN + "/godot-assets"
BUILD_ID = "cloud-uhd0t0dyh3pylvbcsftn"

MODELS = {
    "kk_rig_medium_general.glb": "/animations/kk_rig_medium_general.glb",
    "kk_rig_medium_movementbasic.glb": "/animations/kk_rig_medium_movementbasic.glb",
    "kk_rig_medium_combatmelee.glb": "/animations/kk_rig_medium_combatmelee.glb",
    "kk_Rogue_Hooded.glb": "/characters/kk_Rogue_Hooded.glb",
    "car_player.glb": "/props/kk_city/car_hatchback.glb",
}
AUDIO = {
    "music_city.ogg": "/audio/music/road.ogg",
    "music_town.ogg": "/audio/music/village.ogg",
    "music_country.ogg": "/audio/music/clearing.ogg",
    "crowd.ogg": "/audio/realistic/ambient/town_crowd.ogg",
    "birds.ogg": "/audio/realistic/ambient/forest_birds.ogg",
    "country.ogg": "/audio/realistic/ambient/forest.ogg",
}
TEMPLATE_FILES = [
    "audio_manager.gd", "anim_rig.gd", "build_structure.gd", "cast.gd", "enemy.gd", "layout.gd",
    "rpg_systems.gd", "scene_manager.gd", "surfaces.gd", "traffic.gd", "water.gd", "weather3d.gd",
    "water.gdshader",
    # transitive dependencies of the files above (AnimRig -> GRig, enemy.gd -> GBody/GPose/...)
    "body.gd", "clip_role.gd", "equip.gd", "feet.gd", "pose.gd", "projectile.gd", "rig_map.gd", "vehicle.gd",
]


def download(url: str, target: Path, optional: bool = False) -> bool:
    if target.exists() and target.stat().st_size > 0:
        return True
    target.parent.mkdir(parents=True, exist_ok=True)
    try:
        request = urllib.request.Request(url, headers={"User-Agent": "overland-fetch"})
        with urllib.request.urlopen(request, timeout=60) as response:
            target.write_bytes(response.read())
        return True
    except Exception as error:
        message = f"  ! {url}: {error}"
        print(message + (" (optional)" if optional else ""), file=sys.stderr)
        return optional


def referenced_asset_paths() -> set:
    """Every /godot-assets/... path used by world.json and the scripts."""
    found = set()
    world = ROOT / "world.json"
    if not world.exists():
        sys.exit("openworld/world.json is missing - run tools/gen_world.py first.")
    for text in [world.read_text(encoding="utf-8")] + [p.read_text(encoding="utf-8") for p in ROOT.glob("*.gd")]:
        for match in re.finditer(r'"((?:/godot-assets/)?(?:props|characters|enemies)/[A-Za-z0-9_./\-]+\.glb)"', text):
            path = match.group(1)
            found.add(path if path.startswith("/") else "/godot-assets/" + path)
    return found


def main() -> None:
    print("== library models")
    for name, remote in MODELS.items():
        download(ASSETS + remote, ROOT / "models" / name)
    print("== music + ambience")
    for name, remote in AUDIO.items():
        download(ASSETS + remote, ROOT / "audio" / name)
    print("== signature assets (optional)")
    download(f"{CDN}/{BUILD_ID}/models/fountain.glb", ROOT / BUILD_ID / "models" / "fountain.glb", optional=True)
    download(f"{CDN}/{BUILD_ID}/models/hero.glb", ROOT / "models" / "hero.glb", optional=True)

    print("== template systems + SFX")
    with tempfile.TemporaryDirectory() as tmp:
        archive = Path(tmp) / "tpl.zip"
        download(CDN + "/godot-tmpl-rpg/godot-tmpl-rpg.zip", archive)
        with zipfile.ZipFile(archive) as bundle:
            bundle.extractall(Path(tmp) / "tpl")
        template = Path(tmp) / "tpl"
        for name in TEMPLATE_FILES:
            if not (ROOT / name).exists():
                shutil.copy(template / name, ROOT / name)
        for audio in (template / "audio").iterdir():
            if audio.suffix in (".ogg", ".wav") and not (ROOT / "audio" / audio.name).exists():
                (ROOT / "audio").mkdir(exist_ok=True)
                shutil.copy(audio, ROOT / "audio" / audio.name)

    print("== world props / characters")
    paths = sorted(referenced_asset_paths())
    for index, path in enumerate(paths, 1):
        download(CDN + path, ROOT / path.lstrip("/"))
    print(f"done: {len(paths)} world models, assets restored under {ROOT}")


if __name__ == "__main__":
    main()
