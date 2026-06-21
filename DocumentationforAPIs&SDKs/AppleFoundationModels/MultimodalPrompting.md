# Analyzing images with multimodal prompting

Incorporate images into your prompts to enable the model to analyze and interpret visual content.

Source: https://developer.apple.com/documentation/foundationmodels/analyzing-images-with-multimodal-prompting

Availability: Beta (iOS 26.0+, iPadOS 26.0+, macOS 26.0+, visionOS 26.0+)

## Overview

Apple's Foundation Models framework enables analyzing and interpreting visual content by combining text prompts with images. This multimodal capability supports sophisticated tasks including:

* Image classification
* Document summarization
* Accessibility description generation
* Item identification in photos
* Progress analysis in tutorials (e.g., origami step completion)
* Barcode reading and OCR via Vision integration

The framework performs the necessary scaling and color conversions before passing an image to the model.

## Supported Image Formats

* `CGImage`
* `CIImage`
* `CVPixelBuffer`
* Image URLs (local file URLs)

Wrap images in an `Attachment` or `ImageAttachment` structure and include them directly in `Prompt` alongside text.

## Implementation Approaches

### Basic Image Analysis

Include images using the `Attachment` structure with optional orientation specifications:

```swift
let image: CGImage = // ... your image
let attachment = Attachment(image: image)

let session = LanguageModelSession()
let response = try await session.respond(to: Prompt {
    attachment
    "Describe what you see in this image."
})
```

### Labeling Attachments

Assign stable, unique labels so the model can reference specific photos:

```swift
let prompt = Prompt {
    Attachment(image: supplyPhoto, label: "supplies")
    Attachment(image: inspirationPhoto, label: "inspiration")
    "Based on the supplies photo, suggest craft projects inspired by the inspiration photo."
}
```

### Structured Classification

Use the `@Generable` protocol to create enumerations for predefined categories. Use greedy sampling for deterministic classification:

```swift
@Generable
enum ImageCategory {
    case landscape
    case portrait
    case document
    case food
    case product
}

let session = LanguageModelSession()
let response = try await session.respond(
    to: Prompt {
        Attachment(image: myImage)
        "Classify this image."
    },
    generating: ImageCategory.self,
    options: GenerationOptions(sampling: .greedy)
)
```

### Built-in Vision Tools

Integrate `BarcodeReaderTool` and `OCRTool` from the Vision framework for specialized image analysis:

```swift
let session = LanguageModelSession(
    tools: [BarcodeReaderTool(), OCRTool()]
)
let response = try await session.respond(
    to: Prompt {
        Attachment(image: shelfPhoto)
        "Read all barcodes and extract all text from this image."
    }
)
```

### Custom Image Processing Tools

Create custom tools using `ImageReference` to receive image references within tool arguments:

```swift
struct AnalyzeRegionTool: Tool {
    let name = "analyzeRegion"
    let description = "Analyzes a specific region of interest in the image"

    @Generable
    struct Arguments {
        @Guide(description: "Reference to the image to analyze")
        var imageRef: ImageReference
        @Guide(description: "Region description to focus on")
        var region: String
    }

    func call(arguments: Arguments) async throws -> String {
        // Use Vision framework to analyze the referenced image region
        return "Analysis result"
    }
}
```

### Two-Pass Generation

The Origami sample demonstrates two-pass generation: analyze and classify photos in the first pass, then use that context in subsequent text-only prompts:

```swift
// Pass 1: Analyze image
let analysisSession = LanguageModelSession()
let analysis = try await analysisSession.respond(
    to: Prompt {
        Attachment(image: progressPhoto, label: "progress")
        "Analyze the origami progress shown."
    },
    generating: ProgressAnalysis.self
)

// Pass 2: Generate feedback using analysis context (no image needed)
let feedbackSession = LanguageModelSession()
let feedback = try await feedbackSession.respond(
    to: "Based on this analysis: \(analysis.content). Give coaching feedback."
)
```

## Best Practices

* Use specific prompts: "List all food items in this photo" rather than "Describe this image"
* Consider preprocessing to isolate regions of interest before passing to the model
* Label attachments to help the model identify specific images in multi-image prompts
* Use greedy sampling when you need consistent, deterministic classification results
* Assign stable labels across sessions to enable `ImageReference` linking in structured outputs

## Related

* `Attachment`
  [https://developer.apple.com/documentation/foundationmodels/attachment](https://developer.apple.com/documentation/foundationmodels/attachment)
* `ImageAttachment`
  [https://developer.apple.com/documentation/foundationmodels/imageattachment](https://developer.apple.com/documentation/foundationmodels/imageattachment)
* `ImageReference`
  [https://developer.apple.com/documentation/foundationmodels/imagereference](https://developer.apple.com/documentation/foundationmodels/imagereference)
* Origami: Crafting a dynamic tutorial for Apple Intelligence
  [https://developer.apple.com/documentation/foundationmodels/origami-crafting-a-dynamic-tutorial-for-apple-intelligence](https://developer.apple.com/documentation/foundationmodels/origami-crafting-a-dynamic-tutorial-for-apple-intelligence)
