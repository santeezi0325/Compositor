# The model behind the assistant

What actually runs on a Mac, what this branch builds, and what is still missing.

Written 21 September 2026 against macOS 26.5 (the app's deployment target) and Xcode 26.6
(what CI actually built with — the compiler line in
[run 35648372564](https://github.com/santeezi0325/Compositor/actions/runs/35648372564) reads
`-sdk …/MacOSX26.5.sdk -target arm64-apple-macos26.5`). Everything below is either read from a
primary source, with the link, or read from this repository, with the file. Where something
could not be checked it says so: these containers are Linux with no Xcode and no Apple silicon,
so nothing here was measured on a Mac.

**One date matters more than it looks.** macOS 27 and Xcode 27 went public on 14 September
2026, a week before this was written
([Apple developer releases](https://developer.apple.com/news/releases/): macOS 27.0 (26A428),
Xcode 27 (27A266a)). So macOS 27 below is the *current* Mac release, not a future one, and the
only reason this repository still builds against the 26.5 SDK is that the GitHub runner image
has not picked up Xcode 27 yet. `ci.yml` selects the newest Xcode on the runner, deliberately —
so the SDK will move on its own, with nobody changing a line.

## The short version

Split the assistant in two, because the two halves have completely different answers.

**Understanding an instruction** is solved on device today. Apple's `SystemLanguageModel` ships
with the OS, costs nothing to distribute, needs no API key, and with guided generation it emits
a typed plan rather than prose to be parsed. This branch uses it.

**Generating pixels** is not solved on device today, and Apple is not the answer. There is no
public on-device image-editing model for a third-party Mac app, in any framework. The only
headless generative image API Apple ever shipped has already been removed — that happened on
the release that shipped last week — and its replacement is a modal sheet backed by a server
model. Anything generative has to come from a
third-party model, and the model worth having needs more memory than most Macs will give it.

So: ship the understanding half now over the app's own full-resolution operations, which is
most of the value and all of the reliability, and treat the generative half as a second
project behind the same protocol — starting with a decision about whose hardware it runs on,
because that one is not a detail.

## What Apple gives us

### `FoundationModels`: yes, for understanding

[`SystemLanguageModel`](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)
is an on-device text model, macOS 26.0+. It is a *text* model: it never sees the layer. That is
fine, because the job here is reading "warm it up a bit and take the edge off" and deciding
which of the app's operations that means, not looking at pixels.

- `@Generable` and `@Guide` make it emit a Swift type directly, so there is no prose to parse.
  Generation is *constrained decoding*, which Apple says "fundamentally guarantees structural
  correctness" (WWDC25 session 286) — a `@Generable` enum always comes back as one of its cases.
  Structural validity is guaranteed; being *right* is not.
  ([Generable](https://developer.apple.com/documentation/foundationmodels/generable))
- It is a **~3-billion-parameter, 2-bit-quantized** model, and Apple's own guidance is not to
  use it for logical reasoning or arithmetic. That shaped the plan type: the model picks one
  operation and one strength between −1 and 1, and the app does every conversion into pixels,
  stops and degrees. Asking it to compute a blur radius would be asking the wrong thing of it.
- Availability is a **runtime** condition, not a build-time one: the framework links against the
  macOS 26 SDK regardless, and `SystemLanguageModel.default.availability` reports
  `.available` or `.unavailable(.deviceNotEligible)` / `.unavailable(.modelNotReady)` and so on.
  It needs Apple Intelligence switched on, on Apple silicon, in a supported language — so an
  Intel Mac (macOS 26 is the last Intel release), a Mac with the toggle off, and a CI runner all
  report unavailable. **The keyword planner is therefore not polish, it is the load-bearing
  path** on that hardware and in CI.
- **Verified by this branch's own CI**: `FoundationModelsAssistantPlanner.swift` compiles on a
  GitHub Actions `macos-latest` runner, where Apple Intelligence is certainly not switched on.
- Bundle cost is zero. The weights are a shared OS asset the user downloads by enabling Apple
  Intelligence, so there is no download UX, no cache directory and no first-run wait that we own.

Two things to know, and they are nearer than they read. On **macOS 27 — the release people are
running now** — the model can be given an image: `Attachment`, `ImageAttachmentContent` and
`ImageReference` are all 27.0+, so "make the sky moodier" could be informed by whether there is
in fact a sky. Reaching it means an `if #available(macOS 27, *)` branch, since the deployment
target stays at 26.5; it is a real option today rather than something to wait for.

And `LanguageModelSession.GenerationError` is bounded to 26.0–27.0, superseded by
`LanguageModelError`. Availability in Swift is decided by the **SDK you compile against**, not
by the deployment target — lowering the target does not keep a symbol the 27 SDK has dropped.
This branch names neither type, so it is unaffected; anything that does will break on the build
after the runner image takes Xcode 27, without a commit having changed.

Not verified here: how good the model actually is at picking the right operation, its disk and
RAM cost (Apple publishes neither), and whether `respond(to:generating:)` aborts inference when
its task is cancelled. All need a Mac.

### Vision and Core Image: the operations worth planning over

This is why the planning half is worth shipping on its own. Core Image has around 180
documented built-in filters, deterministic and at full resolution, and Vision adds on-device
subject masking — all with **zero added bundle size and no entitlement** on macOS 26.

One hedge on "no gate", because it was overstated on the first pass. There is no *entitlement*
gate and no Apple Intelligence gate, but `VNGenerateForegroundInstanceMaskRequest` is reported
on [Apple's developer forums](https://developer.apple.com/forums/thread/764948) not to run on
the CPU — forcing a CPU compute device fails with "unsupported compute device", and the symptom
is "Could not create inference context". That is a hardware gate with the same practical effect,
and it leaves two things open that nothing in this branch answers: whether Remove Background
works on a headless CI runner, and how it behaves on an Intel Mac, which macOS 26 still
supports. **No test in this branch runs Vision** — the assistant tests check that the planner
emits `.removeBackground`, never that the filter executes. So CI proves this file compiles, not
that the subject mask works there.

Together that genuinely covers "warm it up a bit", "remove the background", "feather the mask
six pixels", "straighten this". What it cannot do is anything needing new image content, and —
the limit people underestimate — **anything needing semantic selection**. Vision on macOS 26
has no class-labelled segmentation beyond person and unlabelled foreground instances, so
"select the red car" and "select the sky" are out for the same reason "paint a new sky" is.

One precise detail worth knowing, because it bears directly on the full-resolution question:
Vision's two mask outputs are not the same resolution. `generateScaledMask(for:scaledToImageFrom:)`
returns a mask at the input's own size; the raw `instanceMask` is a coarse label buffer that the
app has to upsample. This repository already uses both — `SubjectRemoval.swift:35` takes the
scaled one, `ObjectSelection.swift:46` reads the raw one — and **Remove Background through the
assistant is the scaled path, so it really is full resolution**, which is the part that matters
here.

An earlier draft of this page said the raw buffer is "a fixed 512×512 grid whatever the input
size". Dropped, because the evidence does not carry it: the one measurement behind that figure
covers two roughly 2-megapixel inputs and generalises from them, and WWDC23 session 10176 says
the subject request "produces a soft segmentation mask at the same resolution", which at least
complicates it. The app makes no such assumption either — `ObjectSelection.instanceIndex` reads
`CVPixelBufferGetWidth`/`Height` at runtime (`ObjectSelection.swift:54-55`) rather than hard-coding
a size. Whatever the number is, the shape of the argument is unchanged.

macOS 27 adds click-and-scribble-to-segment
([`GenerateIterativeSegmentationRequest`](https://developer.apple.com/documentation/vision/generateiterativesegmentationrequest)),
which would be the natural way to reach "select that", and it is shipping now rather than
pending. The catch is that it is the sole conforming type of Vision's
`DownloadableAssetsRequest`: the app has to inspect `assetStatus` and call `downloadAssets()`
before the request will run. So it is a 27-only API *and* a network-dependent one with its own
progress UI to own — which breaks the deployment target and the no-weights story at once.
`GenerateForegroundInstanceMaskRequest`, the one this branch actually uses, is macOS 15.0+ and
carries no such conformance.

### Generative pixels: no

Exhaustively checked across ImagePlayground, Vision, Core Image, PhotoKit and PhotosUI.

- **`ImageCreator` is gone, and that is past tense now.** Apple's [June 11 2026 developer
  news](https://developer.apple.com/news/?id=dz9wvq0r): it "will no longer work in iOS 27,
  iPadOS 27, macOS 27, and visionOS 27 or later", and on the public OSes "Your code won't
  compile, and any features in your app that use ImageCreator won't work for people using your
  app." macOS 27 shipped on 14 September. A backend built on it would not be facing a migration
  — it would already be broken on the Macs people are using, and would stop building the moment
  the CI runner takes Xcode 27. This is the single most important thing on this page, because
  `ImageCreator` is the API you would reach for first.
- **It could not have done the job anyway.** It is text-to-image, not image-to-image: an
  existing picture goes in as `ImagePlaygroundConcept.image(_:)`, which WWDC26 session 375 calls
  "a starting point, not a constraint". And on macOS 26 it is style-locked to animation,
  illustration, sketch and emoji — [no photorealistic
  style](https://developer.apple.com/documentation/imageplayground/imageplaygroundstyle).
  For a photo compositor that alone is disqualifying.
- **macOS 27 does add real instruction-driven editing** —
  [`CreationStrategy.editExisting`](https://developer.apple.com/documentation/imageplayground/imageplaygroundoptions/creationstrategy-swift.enum/editexisting),
  which "tries to preserve as much of the original image as possible" — and real photorealism.
  But it is reachable only through the system's own modal sheet, it runs on **Private Cloud
  Compute rather than on device**, and it is metered against the user's iCloud+ plan. That is a
  different shape from `AssistantBackend` in every respect, and it is not on-device inference.
  Worth separating two things here, because they get conflated: the *strategy* is 27.0+, but the
  sheet that carries it is not new at all —
  [`ImagePlaygroundViewController`](https://developer.apple.com/documentation/imageplayground/imageplaygroundviewcontroller),
  `imagePlaygroundSheet`, `sourceImage` and `supportsImagePlayground` are all **macOS 15.1+**, a
  full version below this app's floor. So "Generate with Image Playground…" as an explicit menu
  item, handing the user off to Apple's sheet, is shippable today. It is just not a backend.
- **Photos' "Clean Up" has no public API** in any framework. It is a Photos-app feature.
- **Vision is analytic.** Its requests produce masks and regions, never pixels.
- **Core Image's "generators" are procedural** — checkerboards, stripes, QR codes. Nothing
  diffusion-shaped, nothing that inpaints.

## What this branch builds

Two halves that meet only at `AssistantPlan`, a short list of typed, clamped steps.

```
instruction ──▶ AssistantPlanner ──▶ AssistantPlan ──▶ AssistantPlanRunner ──▶ CGImage
                (needs a model)      (typed, clamped)   (no model at all)
```

**Planners**, tried in order, first one that is ready and produces a plan wins:

| | `FoundationModelsAssistantPlanner` | `KeywordAssistantPlanner` |
|---|---|---|
| Ready when | Apple Intelligence is on and eligible | always |
| Understands | instructions in the user's own words | about a hundred phrasings |
| Multi-step | yes | yes, one clause at a time |
| Deterministic | no | yes, which is why the tests use it |

A planner that fails falls through to the next, so a declined instruction costs vocabulary
rather than the whole assistant. Cancellation is the one error never swallowed — falling
through on a cancel would re-run the instruction the user just stopped.

**The runner** has no model in it. Each step runs at the layer's full resolution:

- `.filter` goes through `PixelFilter.run` (`Compositor/Document/Filters.swift:121`), which is
  the same call the Filter menu's own commit path makes at `Filters.swift:406`. That is ten
  real operations including Vision's
  subject mask (Remove Background) and Content-Aware Fill, already shipping and already tested.
- `.color` is one Core Image chain for the colour work the menus have no entry for —
  saturation, white balance, sharpening, vignette, invert.
- `.mask` is the short list that means anything to an 8-bit matte: invert, feather,
  spread/choke, contrast.

Nothing is reimplemented, and nothing the model says reaches a layer unclamped: every settings
type in this app already has a `normalized` that pins its values to a range, so a model asking
for saturation 400 gets 3.

## Full resolution, and where it stops being a choice

The working default was "the model sees full resolution", taken from `removeBackground`. For
everything this branch ships that is simply true and free: the planner emits numbers, not
pixels, so the operations run on the layer's own raster at whatever size it is. There is no
resampling and no quality loss anywhere in the path.

It stops being free the moment a *generative* model is involved, and the premise is worse than
"commonly around one megapixel" suggests: the two leading open edit models **hard-normalise**
the input in their own reference code. FLUX.1 Kontext picks the nearest of 17 preferred
resolutions, every one about 1.05 MP, and Lanczos-resizes the input to it; Qwen-Image-Edit
computes its dimensions for a target area of exactly 1024×1024. A 6000×4000 layer handed to
Kontext comes back at 1248×832. `AssistantPixels.normalized`
(`Compositor/Document/AssistantBackend.swift:122`) would then write it back at `.high`
interpolation — a 4.8× linear upscale, 23× by area. In a compositor that is the first thing a
user would notice, and it is not recoverable afterwards.

The way out is not a better upscaler. It is noticing that **resampling the model's picture is
only one of three ways to use a model, and it is the worst one.** The edits people ask for split
into three classes, and each gets its own policy:

**Class 1 — the edit is a colour transfer.** Grading, white balance, exposure, film looks, broad
relighting. You never need the model's pixels. Show it about a megapixel, take the before/after
pair it returns, *fit a transform* from that pair, and evaluate the transform on the
full-resolution original. This app already has the delivery vehicle: `CIColorCube` at 33 points per
axis, which is exactly what `HueSaturationFilter` does today
(`Compositor/Document/HueSaturation.swift:234`, `:241`). Bilateral Guided Upsampling is the
published version of this idea and reports 1–2 ms to fit plus about 13 ms to apply on a 10 MP
image. Lossless at full resolution, and the default this should reach for.

**Class 2 — the edit is a region.** Remove the background, brighten the subject, any local
adjustment. Take the model's *mask*, not its pixels, upsample it against the full-resolution
layer, and run Compositor's own full-resolution operation through it.
`GuidedMatte.refine(mask:guide:radius:limit:)` (`Compositor/Document/GuidedMatte.swift:100`) is
already precisely this pattern, written for a different reason: it runs the expensive filter on
a copy no larger than `limit`, scales the radius by the same factor, and draws back up, letting
the full-resolution guide supply the fine detail. A generative backend can reuse it as it
stands.

Prefer it over Core Image's own joint upsample, but for the reason the code gives rather than
the one the comment gives. `GuidedMatte.swift:3–5` says `CIGuidedFilter` "does nothing on this
system and its edge-preserving upsample barely moves the mask" — which runs two filters
together: `CIGuidedFilter` is not a documented public Core Image filter at all, so that half is
unsurprising rather than a platform finding, and `CIEdgePreserveUpsampleFilter` *is* documented
and *is* used in this app, at `ObjectSelection.swift:68`. The real argument is what each call
site does with its result. `ObjectSelection` reaches for the Core Image filter defensively
(`if let filter … else { refined = coarse }`) and then thresholds the output to pure black and
white at `:80`, so nothing subtle survives the trip. `SubjectRemoval` wants a soft matte that
keeps hair, and for that it uses `GuidedMatte.refine` (`SubjectRemoval.swift:51`). A mask being
lifted to full resolution is the second case.

**Class 3 — the edit invents content.** Inpainting, object removal, adding or replacing things,
restyling. Here there is no lossless path and no amount of cleverness makes one. The honest
answer is to crop a native-sized window *at full resolution* around the region so the model sees
real pixels, edit that, and composite it back through
`PixelAdjust.blend(_:over:through:pixelToDocument:isMask:)`
(`Compositor/Document/PixelAdjust.swift:38`), which blends in float with no colour conversion so
fully-selected pixels stay exact. Where the region is genuinely bigger than the model's native
size, say so in the UI rather than silently upscaling.

**Tiling does not rescue class 3**, which is worth stating because it is the obvious idea. Tiled
diffusion was built to make large *generations* fit in small VRAM: every tile gets the same
prompt (ControlNet Tile exists because that fails), and a tile holding half a lamppost has no
idea what the other half looked like. It also does not lower the per-tile memory peak, so it
buys nothing on the machine that needed help. On the measured numbers below, a 24 MP layer at
1248×832 tiles is 25 tiles edge-to-edge, about 36 with overlap — 33 minutes at best, several
hours at worst, for one edit behind a text field.

None of this needs the boundary to change shape, which is the point worth keeping.
`AssistantResult` is `.pixels(CGImage)` and nothing in the protocol says those pixels came out of
a model: a backend can downsample with `DownsampleCache` (Lanczos halvings,
`Compositor/Rendering/DownsampleCache.swift:13`), run the model at 1 MP, fit a cube, apply it to
the full-resolution `request.image`, and return a full-size `CGImage` — at which point
`normalized` takes its same-size branch at `AssistantBackend.swift:129–130` and copies with
`.none` interpolation. Zero resampling loss, entirely inside the backend.

One seam limit does get in the way, and it is class 2's: a backend cannot return a *mask* for a
pixel target. `EditorSession+Assistant.swift:143` refuses that with
`AssistantError.wrongOutput`, deliberately, because writing pixels onto a mask target destroys a
layer silently. So "here is a region I found; now run your own full-resolution blur through it"
is unexpressible today. A backend can work around it by applying the operation itself and
returning `.pixels`, at the cost of owning the operation instead of reusing `PixelFilter`. If
the generative half gets built, this is the one change to the boundary worth making.

*Single-source and unmeasured, like everything else here:* the resolution behaviour is read from
the models' own reference code, and the timings come from one report each — a 16 GB M2 mini at
about 760 s for FLUX.1-dev at 1024² (swapping 4.6 GB), an M1 Max Studio at about 80 s for
Qwen-Image-Edit-2511 at four steps. There is one credible counter-claim I could not confirm: a
ComfyUI issue reports Qwen-Image holding up between 1.5 and 17 MP, with quality *improving* as
resolution rises. If that is true the arithmetic changes materially, and it is the cheapest
single experiment to run on a real Mac before building anything.

## Limits of the seam itself

Worth knowing before anyone plans around it, and true no matter what model goes behind it:

- **A backend can only replace a layer's pixels in place.** `AssistantPixels.normalized`
  resamples the result to exactly the source's width and height, so the assistant cannot change
  a layer's size or transform. No crop, no resize, no outpainting, and no blur that spreads past
  the layer's edge the way the Filter menu's own padded path allows.
- **Content-Aware Fill needs a selection**, so "remove that lamppost" only works if the user
  selected it first. The assistant cannot make the selection itself — it never sees the image.
- **Blurring one part of a picture is not reachable.** "Blur the background" blurs the layer.
  Region-aware editing needs the planner to be able to ask for a mask, which is the natural next
  step and is not in this branch. Note that even with it, the region has to be one Vision can
  find: the subject, or the foreground. There is no "the sky" and no "the red car" on macOS 26.

## If you want generative editing

It has to be a model we ship and run ourselves. It is buildable on a Mac today by one engineer,
but not where you would look first.

**MLX Swift is not the answer, which was a surprise.** `mlx-swift-examples` ships exactly two
libraries, MLXMNIST and StableDiffusion, and the StableDiffusion one has had no substantive
commit since June 2025. The only model in it that does image-to-image is SDXL-Turbo, whose
weights are non-commercial. And SDXL img2img is **not instruction editing** anyway: it
VAE-encodes the image, renoises it, and denoises against a prompt describing the *target
picture*. "Make the sky stormier" is read as a caption, not as a command — which is exactly the
distinction that matters for an assistant. There is no FLUX.1 Kontext, Qwen-Image-Edit,
Step1X-Edit or OmniGen in `mlx-swift-examples`, and none in ml-explore's *Python* `mlx-examples`
either.

Swift ports of the real edit models do exist outside ml-explore, and the licence is what rules
them out rather than the maturity. [`mzbac/flux.swift`](https://github.com/mzbac/flux.swift) is
mlx-swift-based, has 123 stars, and genuinely runs **FLUX.1-Kontext-dev**, image-to-image — it
is the one thing found anywhere that follows an edit instruction in Swift on a Mac today. It is
**GPLv3** (read from its `LICENSE` file, not from a badge), which for an MIT app distributed on
the Mac App Store is the end of the conversation, and Kontext's weights are non-commercial on
top of that. The same author's
[`flux2.swift`](https://github.com/mzbac/flux2.swift) is **Apache-2.0** and does FLUX.2 klein
image-to-image, which clears the licence on both code and weights — but it has 7 stars, and
that is the whole of the usable Swift ecosystem. For contrast,
[`liuliu/swift-diffusion`](https://github.com/liuliu/swift-diffusion) is BSD-3-Clause and well
maintained, but it is Stable Diffusion v1.4 on the author's own s4nnc framework: no Kontext, no
instruction editing.

**Core ML is not the answer either**, which is the other place you would look. Apple's
`ml-stable-diffusion` Swift package does implement image-to-image — shipping Mac apps prove it
— but img2img is the "rewrites everything against a caption" behaviour, not instruction
following. Converted InstructPix2Pix weights exist, yet the Swift pipeline cannot drive them:
it builds the 8-channel latent from pure noise instead of concatenating the image latent, and
does two-way classifier-free guidance where InstructPix2Pix needs three. Making it work means
forking and reimplementing the denoising loop, against a repository whose newest dependency pin
is from September 2024 and whose SD3 path depends on a project archived in March 2026.

**The runtime that actually does this today is C++.** `stable-diffusion.cpp` is MIT, has a Metal
backend, is actively developed, and supports FLUX.1-Kontext, the Qwen-Image-Edit series and
FLUX.2 klein — models that genuinely follow an edit instruction. Decisively for this boundary,
it exposes `sd_cancel_generation()`, so the cancellation `AssistantBackend.run` promises is real
rather than aspirational. There is no SwiftPM package; you build an xcframework and add a C
interop target, the way whisper.cpp is usually consumed.

Two things to decide with it, in this order:

- **Licence, before anything else.** FLUX.2-klein and Qwen-Image-Edit are Apache-2.0. FLUX.1
  Kontext is not — it is the best-known of the three and the one you cannot ship commercially.
- **Size.** GGUF through `stable-diffusion.cpp` is far kinder than MLX snapshots: the project
  claims Kontext runs in 4–6 GB, against roughly 16 GB for a FLUX.2-klein bf16 MLX snapshot and
  about 60 GB for Qwen-Image-Edit-2511 in MLX, which rules that one out. Either way the weights
  are a multi-gigabyte download that cannot live in the app bundle, so they go in the app's own
  container — which, per the table above, needs no entitlement.

Memory is the constraint to watch, because it is unified and therefore competes with the open
document. The best figure found was FLUX.2-klein-4B with encoder eviction: about 5 GB resident
and a 10 GB peak at 768², described as fitting in 16 GB. Treat every number in this section as
single-source and unmeasured until someone runs it on a real Mac — none of it could be checked
from here.

The shape it would take is a second planner operation — one that says "hand the whole layer to
the generative backend with this prompt" — plus a `GenerativeBackend` behind it. The
`AssistantBackend` protocol does not need to change to accommodate it, which was the point of
keeping it neutral.

### What `onda-ai` already solves, and what it decides

`santeezi0325/onda-ai` is a model-agnostic capability gateway. It is **TypeScript** — zero
runtime dependencies, plain `fetch` — so it cannot be linked into a Swift app. Compositor would
reach it over HTTP, which is the local-server row of the table above: no entitlement change.

It already has the capability we need. `AIGateway.editImage(ctx, { prompt, image, seed, signal })`
takes a base64 `ImagePart` and returns image URLs or data URIs
(`packages/ai/src/gateway.ts:373`). It takes an `AbortSignal`, so the cancellation this boundary
promises maps straight through rather than being bolted on.

Its registry picked `qwen-image-edit-2511` — Apache-2.0, 20B, instruction-based editing of a
supplied photo, described there as "the genuinely self-hostable answer"
(`packages/ai/src/registry/catalog.ts:376`). That is worth noting because the survey above
arrived at the same model independently, from the opposite direction: Qwen-Image-Edit is one of
the two Apache-2.0 families `stable-diffusion.cpp` supports. Same weights, two different places
to run them.

So the decision is not *which model*. It is **whose hardware**, and `onda-ai` is explicit that
this is a boundary question rather than a performance one: every deployment declares itself
`private` (our GPU), `processor` (a third party running open weights) or `vendor` (a proprietary
API), and the router fails rather than exceeding what a request allows.

| | Through `onda-ai` | On the user's Mac |
|---|---|---|
| How | HTTP to the gateway | `stable-diffusion.cpp` xcframework, GGUF weights |
| Already built | the gateway, the registry, licence diligence, fallbacks, metering | nothing |
| Still to build | the OpenAI-shaped image endpoint, which the catalog notes does not exist yet | C interop, weight download, the whole path |
| Where the photo goes | off the Mac, to `private` or `processor` hardware | nowhere |
| Hardware | 24 GB VRAM minimum quantized, 48 GB comfortable | a 24 GB-class Mac at best; not a 16 GB one |
| Credentials | none for the self-hosted deployment (`keyOptional: true`); a token for Replicate | none |

The honest reading: **`qwen-image-edit-2511` will not run on most users' Macs.** `onda-ai`'s own
deployment notes put a 16 GB Mac at roughly 10–11 GB of GPU working set, against a 24 GB
floor for this model quantized. So "inference on device" and "generative editing" are, for now,
close to mutually exclusive on the hardware a Compositor user actually has — which is the real
finding, and the thing to decide before any of this gets built.

The two are not exclusive as *code*, though. Both sit behind `AssistantBackend` and can coexist:
full-resolution adjustments locally with no network at all, and generative edits through
whichever of the two you pick. That is what the neutral protocol bought.

### What the sandbox allows, whichever model it is

`Config/Compositor.entitlements` decides more about this than the model does. The app declares
`com.apple.security.app-sandbox`, `com.apple.security.network.client`,
`com.apple.security.files.user-selected.read-write`, and a mach-lookup exception for Sparkle's
two helpers. Nothing else — in particular **no `network.server`**, so the app cannot listen on
a port, and no entitlement that would let it read arbitrary places on disk.

That maps onto the three shapes a model can arrive in:

| Shape | Works today? | What it costs |
|---|---|---|
| A Swift package linked into the app | Yes | Weights live in the app's own container, which needs no entitlement; downloading them uses `network.client`. Cleanest, but we own the download UX and the disk. |
| A helper binary we ship | Probably, with work | It has to live inside the app bundle and it inherits the sandbox; signing and notarizing a second executable is real work. The app cannot run a binary the *user* installed — that is outside what it may read and execute. |
| A local server on `localhost` | **Yes, with no change at all** | `network.client` already covers connecting out, including to a loopback port. Costs nothing in entitlements, weights or bundle size. The price is that the app depends on something the user installed and started. |

The third row is the surprising one and worth knowing before picking: if a model already runs
as a local HTTP server, reaching it needs nothing from this app that is not already there.

`network.client` would equally allow a *remote* API, but that runs into a different wall: the
app has no secrets mechanism anywhere, so there is nowhere to put a key.

Not verified here: exactly what a sandboxed app may `posix_spawn`. The entitlements above are
read from the file; the spawn rules are from Apple's sandbox model and were not tested on a Mac.
