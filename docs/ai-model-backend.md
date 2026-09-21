# The model behind the assistant

What actually runs on a Mac, what this branch builds, and what is still missing.

Written 21 September 2026 against macOS 26.5 (the app's deployment target) and Xcode 26.6
(what CI runs). Everything below is either read from a primary source, with the link, or read
from this repository, with the file. Where something could not be checked it says so: these
containers are Linux with no Xcode and no Apple silicon, so nothing here was measured on a Mac.

## The short version

Split the assistant in two, because the two halves have completely different answers.

**Understanding an instruction** is solved on device today. Apple's `SystemLanguageModel` ships
with the OS, costs nothing to distribute, needs no API key, and with guided generation it emits
a typed plan rather than prose to be parsed. This branch uses it.

**Generating pixels** is not solved on device today, and Apple is not the answer. There is no
public on-device image-editing model for a third-party Mac app, in any framework. The only
headless generative image API Apple ever shipped is being removed at macOS 27, and its
replacement is a modal sheet backed by a server model. Anything generative has to come from a
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

Two things to know for later. On **macOS 27** the model can be given an image —
`Attachment`, `ImageAttachmentContent` and `ImageReference` are all 27.0+ — so "make the sky
moodier" could one day be informed by whether there is in fact a sky. And
`LanguageModelSession.GenerationError` is bounded to 26.0–27.0, superseded by
`LanguageModelError`; this branch does not name either type, but anything that does will need
attention when the app builds against the Xcode 27 SDK.

Not verified here: how good the model actually is at picking the right operation, its disk and
RAM cost (Apple publishes neither), and whether `respond(to:generating:)` aborts inference when
its task is cancelled. All need a Mac.

### Vision and Core Image: the operations worth planning over

This is why the planning half is worth shipping on its own. Core Image has around 180
documented built-in filters, deterministic and at full resolution, and Vision adds on-device
subject masking — all with **zero added bundle size, no entitlement and no availability gate**
on macOS 26.

Together that genuinely covers "warm it up a bit", "remove the background", "feather the mask
six pixels", "straighten this". What it cannot do is anything needing new image content, and —
the limit people underestimate — **anything needing semantic selection**. Vision on macOS 26
has no class-labelled segmentation beyond person and unlabelled foreground instances, so
"select the red car" and "select the sky" are out for the same reason "paint a new sky" is.

One precise detail worth knowing, because it bears directly on the full-resolution question:
Vision's raw `instanceMask` is a **fixed 512×512 grid** whatever the input size, while
`generateScaledMask(for:scaledToImageFrom:)` returns a mask at the input's own resolution. The
app already uses both — `SubjectRemoval.swift:35` takes the scaled one, `ObjectSelection.swift:46`
takes the low-resolution one and upsamples. Remove Background through the assistant is the
scaled path, so it really is full resolution.

macOS 27 adds click-and-scribble-to-segment (`GenerateIterativeSegmentationRequest`), which
would be the natural way to reach "select that" — but it is 27-only and downloads its own
weights, so it breaks both the deployment target and the no-weights story.

### Generative pixels: no

Exhaustively checked across ImagePlayground, Vision, Core Image, PhotoKit and PhotosUI.

- **`ImageCreator` is discontinued.** Apple's [June 11 2026 developer
  news](https://developer.apple.com/news/?id=dz9wvq0r): it "will no longer work in iOS 27,
  iPadOS 27, macOS 27, and visionOS 27 or later" and "Your code won't compile". On beta OSes it
  already "will not function in TestFlight builds". A backend built on it would be a forced
  migration at the next major OS and an unshippable beta before that. This is the single most
  important thing on this page, because `ImageCreator` is the API you would reach for first.
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

It stops being free the moment a *generative* model is involved, because those have a native
resolution — commonly around one megapixel — and a 24-megapixel layer is not that. The
boundary resamples whatever comes back onto the target's own grid, so a 1024×1024 result
written onto a 6000×4000 layer is an upscale. That is not a bug in the boundary; it is the real
trade, and it is the reason "full resolution" cannot be answered once for the whole assistant.
It has to be answered per class of edit.

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
either. Swift ports of the real edit models exist, but they are one-author projects — the
hub for several of them has one star and a README saying it is not ready for use.

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
