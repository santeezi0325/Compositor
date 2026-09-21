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
third-party model we ship and run ourselves, and that is a separate, much larger piece of work.

So: ship the understanding half now over the app's own full-resolution operations, which is
most of the value and all of the reliability, and treat the generative half as a second
project behind the same protocol.

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

It has to be a model we ship and run ourselves. That is a real project, not a wiring job, and
the honest scoping questions are: what runs in Swift rather than only in Python, what it costs
in memory next to a photo document, whether it can be cancelled mid-generation, and how
multi-gigabyte weights reach a user's Mac. Those are being checked separately.

The shape it would take here is a second planner operation — one that says "hand the whole
layer to the generative backend with this prompt" — plus a `GenerativeBackend` behind it. The
`AssistantBackend` protocol does not need to change to accommodate it, which was the point of
keeping it neutral.
