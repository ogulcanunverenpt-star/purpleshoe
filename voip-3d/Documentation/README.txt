Alone in the Dusk
Maciej EmacEArt
================================================================

WHAT THIS IS
  A low-poly environment kit for Godot 4 with a PSX-era look: a dusk
  roadside world of covered bridges, stone walls, dirt roads, fences,
  rocks and lamps, plus the shaders that give it the late-90s console
  picture.

HOW TO ADD IT TO YOUR PROJECT
  Open this folder as its own Godot project first (Godot project
  manager -> Import -> pick project.godot here) and run the demo scene
  to see the kit as it is meant to look.

  To bring it into your own game, copy the WHOLE pack folder into your
  project, then attach Shaders/psx_setup.gd to any node in your scene.
  That second step is the one to know about. The shaders read six
  numbers that Godot keeps under Project Settings -> Shader Globals,
  and that list belongs to the project you are in, not to the shader
  files. Copying the folder therefore brings the shaders and not the
  numbers, and a material with nothing behind its numbers comes out
  untextured. psx_setup.gd creates the missing entries for you, in the
  editor and in a running game alike, and leaves alone any entry you
  already have, so values you tuned yourself stay as you set them.

  There is no plugin to enable and nothing to copy by hand.

WHAT IS WHERE
  Meshes/         96 models in .glb, one flat folder. Each file carries
                  its own colour map, so a model opened in Blender,
                  Unity or a bare Godot project arrives textured rather
                  than blank. Inside this pack those embedded copies are
                  ignored: the import settings point every model at the
                  full resolution material in Materials/
  Prefabs/        ready-to-use object scenes (.tscn) grouped by kind -
                  these are what you instance in your own scenes
  Materials/      15 materials
  Textures/       14 colour atlases
  Scenes/         Demo.tscn (the main scene) and ShowroomAssets.tscn,
                  which lines up every model in the pack
  Player/         a simple first-person walker for trying the scenes
  Shaders/        5 shaders: surfaces, terrain, light shafts, the sky
                  and the screen pass, plus psx_setup.gd, which carries
                  the look into a project that has never seen this pack
  Documentation/  this file, licence, contents list

HOW TO USE
  Drag a .tscn from Prefabs/ into your scene, or use "Instantiate Child
  Scene". Every object arrives with its mesh and material already set.

  The screen pass is a node, not a script: PSXScreenPass in the demo
  scene is a CanvasLayer with a full-rect ColorRect on it. Copy that
  pair into your own scene and the whole frame gets the console
  resolution and the dither.

THE LOOK IS BAKED IN
  This is the free kit, and it ships with one picture: the dusk look of
  the demo scene. The sky, the screen pass and the material shader
  carry their settings as constants, so a scene opens the same way in
  every project and there is nothing to retune by hand.

  Six numbers are left in Project Settings -> Shader Globals, so the
  whole scene can still be moved together if you want to: simulated
  texture resolution, colour steps, vertex jitter, texture warp, dither
  strength and the rendered screen height.

PIXEL SIZE IS MEASURED IN THE WORLD, NOT PER MODEL
  Every material carries its own simulated texture resolution, worked
  out from how many metres of surface its texture covers. The result is
  one pixel size across the whole scene - a wall, a bridge and the
  ground all show the same grain.

ART STYLE
  Low-poly meshes with hand-painted colour atlases, no normal or
  specular maps - the picture comes from the geometry, the palette and
  the shader. Textures are meant to stay unfiltered; if your project
  switches the import filter to linear, the pixels blur.

TESTED ON
  Godot 4.7.1, Forward+ renderer

LICENSE
  EmacEArt Asset License - free to use in your own projects, personal
  and commercial alike. No credit is required, though it is always
  welcome.

  One favour in return: please do not resell the assets or pass them on
  as standalone files or inside another asset pack. This is a
  one-person studio, and that goodwill is what pays for the next pack.

CONTACT
  Website: emaceart.dev
  Discord: https://discord.com/invite/ctXaf5Ftqw

================================================================
