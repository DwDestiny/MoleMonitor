# DogArt provenance

Source of these images: AI image generation, 2026-10-12. Model: `gpt-image-2.5` through an OpenAI-compatible relay.
Not hand drawn. Not covered by the GPL-3.0-only license of the code. See `docs/ASSETS.md` for the license statement.

## How they were made

1. Reference: one standing Bichon illustration made by the same model from a text prompt.
2. `edit` calls with that reference and `background=transparent`, asking for one row of separated poses.
3. Cleanup with a script: alpha floor 80, alpha ceiling 200, small specks removed, one connected component per pose.
4. Each pose scaled with one common factor (the walk pose with its own factor, 0.9 of the stand height), bottom aligned, on a 320 x 240 px canvas.
5. `dog_gray.png` is `dog_stand.png` with all color removed.

## Prompt (poses lie, stand, trot, sprint, pant, alert)

Keep exactly the same Bichon dog: same fluffy white curly coat, same face, same style, proportions and outline.
Create 6 separated full-body poses of this dog in one single horizontal row, evenly spaced, same scale, all facing right
in side view, for a status mascot. Poses left to right: lying down resting with eyes half closed, standing calmly,
trotting briskly with legs mid-stride, sprinting at full speed with ears blown back and legs stretched, standing and
panting hard with open mouth, long tongue out and one small blue sweat drop, standing alert with ears lifted and head
tilted looking worried. No shadows, floor, text, frame numbers, grid lines, motion trails, speed lines, glow or detached particles.

## Replacement poses (second pass, 2026-10-12)

The first versions of pant, alert and walk shared the stand silhouette. The gate BD (pairwise silhouette difference at
72 x 54 pt) failed for 4 pairs. These 3 files were generated again with one `edit` call (same reference, transparent
background, 4 poses in one row) and replace the first versions.

Prompt: same dog and style rules as above. Poses: sitting upright on its haunches with head tilted up, mouth wide open,
long tongue hanging out, one small blue sweat drop (used for `dog_pant.png`); sitting facing the viewer front-on with both
ears lifted, worried wide eyes, looking up (used for `dog_alert.png`); walking slowly with head lowered sniffing the ground,
facing right (used for `dog_walk.png`, scaled to 0.80 of the stand height). A fourth pose (play bow) is not used.

## Third pass (2026-10-12): alert

The front-on alert pose was a different camera from the other 6 poses (G2 review, round 1). `dog_alert.png` was generated
again: same reference, 4 candidates in one row, side view, body facing right, sitting upright, ears lifted, wide worried
eyes, mouth closed, head turned slightly towards the viewer, no tongue, no sweat drop. The second candidate is used,
scaled to 0.95 of the stand height.

## Prompt (first version of pose walk, replaced)

Same dog, 3 separated poses in one row, relaxed slow walk with one front paw lifted, mouth closed, happy eyes,
tail curled up. The middle pose is used.

## Files

| File | Used for |
|---|---|
| dog_lie.png | CPU gait lie |
| dog_stand.png | CPU gait stand |
| dog_walk.png | CPU gait walk |
| dog_trot.png | CPU gait trot |
| dog_sprint.png | CPU gait sprint |
| dog_pant.png | Overlay panting (thermal serious or critical) |
| dog_alert.png | Overlay attention (worst problem yellow or red) |
| dog_gray.png | Collecting or stale |

## Action strips for panel v2 (`Resources/DogSprites/`, 2026-10-12)

Source: AI image generation, 2026-10-12. Model: `gpt-image-2.5` through the same OpenAI-compatible relay.
Not hand drawn. Not covered by the GPL-3.0-only license of the code. The license questions A1 to A5 in
`docs/ASSETS.md` apply to these files too and stay open for the user.

### How they were made

1. Reference: `dog_stand.png` (this folder) is the only reference image for every strip, except `stand_up`.
   The `stand_up` call has two references: frame 6 of `lie_idle.png` mirrored back to face right, and `dog_stand.png`.
2. One `edit` call per strip, size 1536 x 1024, `background=transparent`, one row of N frames.
   23 calls in total: walk 1, trot 2, sprint 3, lie_idle 2, pant_lie 3, sniff 2, stand_up 7, wag 1, notice 2.
   Two more calls make the two bed props (see "Bed props" below), so the panel v2 art used 25 calls.
   The table below names the call that is used. The other calls were rejected after review or measurement.
3. Cleanup with a script: alpha floor 80, alpha ceiling 200, components under 3000 px removed,
   one connected component per frame, left to right.
4. Each frame mirrored, so the dog faces left (`docs/DESIGN_V2.md` 4.2).
5. One scale factor per strip, chosen so that the eye-nose triangle of the frames has the same size as in
   `dog_stand.png` (head size match). For `stand_up`, the area of the last frame first matches the
   standing area, then the same head size rule applies. Its standing frame is 201 px high (reference 210 px).
6. Each frame on a 320 x 240 px canvas, lowest opaque pixel on y = 230, centered on the upper body.
7. Registration: horizontal shifts of at most 18 px, chosen so that the silhouette change between
   neighbouring frames is as small as possible. No frame is redrawn, blended or recolored.
8. Frame order changes (only where noted): pant_lie uses strip frames 1, 5, 6, 2, 6, 5 (a ping-pong loop
   with a smaller head movement), sprint uses strip frames 3 to 8 of 8, sniff moves strip frame 8 to position 2,
   stand_up uses strip frames 1, 3, 4, 5, 6, 8 of 8.
9. `sit_gray.png` is `dog_gray.png` mirrored. It is not generated.
10. PNG files are lossless (Pillow `optimize`). No quantization. 10 PNG files, 2.34 MB in total.

### Prompt (common part of every call)

Keep exactly the same Bichon Frise puppy as the reference image: same fluffy white curly coat, same round fluffy
head, same face with two big shiny dark eyes and a small black nose, same soft 3D illustration style, same body
proportions and outline, same size. This is an animation sprite strip for a cute app mascot.
[action part]
All frames: one single horizontal row, evenly spaced with clear empty gaps between frames, exactly the same scale,
all standing on the same invisible ground line, body in side view facing right, head turned slightly towards the
viewer so both eyes and the nose are visible in every frame. Consecutive frames change smoothly, like real animation
in-betweens. Transparent background. No shadows, no floor, no text, no frame numbers, no grid lines, no motion
trails, no speed lines, no glow, no detached particles, no logos.
(The calls for sprint, pant_lie, sniff and stand_up attempts 3 to 7 also ask for a wide empty margin at the left and right edges.)

### Action parts (the calls that are used)

| File | Call | Action part of the prompt |
|---|---|---|
| walk.png | walk 1 | 8 frames of one relaxed happy walk cycle; legs alternate clearly (contact, passing with a front paw lifted, mirrored); tail curled up, gentle head bob, small smile, mouth closed |
| trot.png | trot 2 | 8 frames of one brisk happy trot, body level with a tiny bounce, diagonal legs move together and alternate clearly, small change per frame, mouth slightly open with a small pink tongue |
| sprint.png | sprint 3 | 8 frames of one fast gallop; head, body, tail and ears stay almost in place, body stretched and low, ears blown back, mouth open; only the legs cycle |
| lie_idle.png | lie_idle 2 | 6 frames of one calm resting loop; lying on the belly, chin on the front paws, eyes open; visible slow breathing and a slow tail wag |
| pant_lie.png | pant_lie 3 | 6 frames of one hot panting loop; lying flat with the hind legs stretched back, head raised, eyes open and gentle, mouth open with a long pink tongue; head moves up and down; no sweat drops |
| sniff.png | sniff 2 | 8 frames of one curious sniffing loop; standing, head lowered, nose near the ground, small steps, tail wags; same bright white coat as the reference |
| stand_up.png | stand_up 6 | 8 frames of getting up slowly, each frame a little different from the previous one: the lying pose of the first reference, chin lifts, head up, front paws move out and chest lifts, chest higher with bent elbows, front legs almost straight, back end half way up, the standing pose of the second reference; hind paws stay in place, same size in every frame |
| wag.png | wag 1 | 6 frames of one happy play-bow loop; front low, rear end raised, open-mouth smile; the tail wags from side to side |
| notice.png | notice 2 | 4 frames of noticing something while sitting upright: relaxed, head lifts, head turns to the viewer, alert with wide eyes; ears stay long and floppy |
| sit_gray.png | none | `dog_gray.png` mirrored |

### Bed props (`Resources/DogSprites/bed_some.png`, `bed_full.png`)

The stage shows the bed of the dog when the disk is yellow (`bed_some`) or red (`bed_full`), `docs/DESIGN_V2.md` 4.2 and 4.4.
Two `edit` calls, 1536 x 1024, `background=transparent`, reference `dog_stand.png` for the style only.
The first call (a beige round bed with small cubes) was rejected: at 96 x 56 pt it read as a food bowl with kibble.
The used call is the second one. Prompt: "Same soft 3D illustration style, same lighting and same rendering as the reference
puppy image. Draw two separated objects side by side on a transparent background, both the same size, seen from the front and
slightly above, wide and low (about twice as wide as high). Both are the same dog bed: an oval plush pet bed with a thick soft
bolster rim in muted blue-gray fabric, a lighter cream cushion inside, and a clear low dip in the front rim where a dog steps in,
so it reads as a dog bed and not as a bowl. Left: the bed holds two cardboard shipping boxes, each box clearly a box with folded
top flaps and one darker brown tape strip across the top, the bed is half full. Right: exactly the same bed overfilled with six
cardboard shipping boxes of the same kind stacked high above the rim, one box leaning over the edge, clearly too full. The boxes
are large compared with the bed, only a few of them, not small cubes. No puppy, no shadows, no floor, no text, no labels, no
logos, no print on the boxes, no glow. Wide empty margin around both objects."
Cleanup: the same alpha floor and ceiling as the strips. One common scale for both beds, so the two beds have the same size.
Each bed on a 192 x 112 px canvas (96 x 56 pt), lowest pixel on y = 108 px.

