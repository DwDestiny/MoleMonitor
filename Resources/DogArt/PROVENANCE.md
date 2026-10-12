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
