import Testing
@testable import AITaskRunner

// MARK: - MCP content → MCPToolResult

@Suite("MCP image content")
struct MCPImageContentTests {
    @Test("Images are collected in order and each gets a numbered placeholder")
    func extractCollectsImages() {
        let content: JSONValue = [
            ["type": "text", "text": "Rendered 2 page(s)."],
            ["type": "image", "data": "AAAA", "mimeType": "image/png"],
            ["type": "image", "data": "", "mimeType": "image/png"],
            ["type": "image", "data": "BBBB", "mimeType": "image/bmp"],
            ["type": "resource", "resource": ["uri": "file:///x.jpg", "blob": "CCCC", "mimeType": "image/jpeg"]],
            ["type": "resource", "resource": ["uri": "file:///y.txt", "text": "hello"]],
            ["type": "image", "data": "DDDD", "mimeType": "IMAGE/WEBP; charset=binary"],
        ]
        let (text, images) = MCPConnection.extract(content: content)
        #expect(images == [
            MCPImage(mimeType: "image/png", base64: "AAAA"),
            MCPImage(mimeType: "image/jpeg", base64: "CCCC"),
            MCPImage(mimeType: "image/webp", base64: "DDDD"),
        ])
        #expect(text == """
            Rendered 2 page(s).
            [image 1: image/png]
            [image image/png: empty]
            [image image/bmp: not supported]
            [image 2: image/jpeg]
            hello
            [image 3: image/webp]
            """)
        #expect(MCPConnection.flatten(content: content) == text)
    }

    @Test("Text-only content and plain strings are unchanged")
    func extractWithoutImages() {
        #expect(MCPConnection.extract(content: "plain").images.isEmpty)
        #expect(MCPConnection.extract(content: "plain").text == "plain")
        let (text, images) = MCPConnection.extract(content: [["type": "text", "text": "a"], ["type": "text", "text": "b"]])
        #expect(text == "a\nb")
        #expect(images.isEmpty)
    }

    @Test("Models without image input get a note instead of the images")
    func textDescribingImages() {
        let result = MCPToolResult(text: "[image 1: image/png]", isError: false, images: [MCPImage(mimeType: "image/png", base64: "AAAA")])
        #expect(result.textDescribingImages == "[image 1: image/png]\n[1 image(s) returned; this model cannot see images]")
        #expect(MCPToolResult(text: "x", isError: false).textDescribingImages == "x")
    }

    @Test("The image budget keeps a prefix of the images and says how many were dropped")
    func imageBudget() {
        let image = MCPImage(mimeType: "image/png", base64: String(repeating: "A", count: 800)) // 600 decoded bytes
        var result = MCPToolResult(text: "x", isError: false, images: [image, image, image])
        ToolBox.applyImageBudget(to: &result, budget: 1_300)
        #expect(result.images.count == 2)
        #expect(result.text == "x\n[1 image(s) dropped: result exceeded the image budget]")

        var untouched = MCPToolResult(text: "x", isError: false, images: [image])
        ToolBox.applyImageBudget(to: &untouched)
        #expect(untouched.images.count == 1)
        #expect(untouched.text == "x")
    }
}

// MARK: - OpenAI-compatible messages

@Suite("OpenAI image messages")
struct OpenAIImageMessageTests {
    let images = [
        MCPImage(mimeType: "image/png", base64: String(repeating: "A", count: 40_000)),
        MCPImage(mimeType: "image/jpeg", base64: "/9j/"),
    ]

    @Test("Two images become one user message with a text part and two image_url parts")
    func userMessageFromToolResult() throws {
        let result = MCPToolResult(text: "[image 1: image/png]\n[image 2: image/jpeg]", isError: false, images: images)
        let message = OpenAIEngine.imageMessage(toolName: "pii__render_pages", images: result.images)
        #expect(message["role"]?.string == "user")
        let parts = try #require(message["content"]?.array)
        #expect(parts.count == 3)
        #expect(parts[0]["type"]?.string == "text")
        #expect(parts[0]["text"]?.string == "Images returned by pii__render_pages (2):")
        #expect(parts[1]["type"]?.string == "image_url")
        #expect(parts[1]["image_url"]?["url"]?.string == "data:image/png;base64," + images[0].base64)
        #expect(parts[2]["type"]?.string == "image_url")
        #expect(parts[2]["image_url"]?["url"]?.string == "data:image/jpeg;base64,/9j/")
    }

    @Test("An image message is estimated at a fixed cost per image plus its text, never its base64")
    func estimateTokensForImageMessage() {
        let message = OpenAIEngine.imageMessage(toolName: "t", images: images)
        let tokens = OpenAIEngine.estimateTokens(message)
        let textOnly = OpenAIEngine.estimateTokens(["role": "user", "content": [["type": "text", "text": "Images returned by t (2):"]]])
        #expect(tokens == 2 * OpenAIEngine.imageTokenEstimate + textOnly)
        #expect(tokens >= 3_000 && tokens < 3_050)
        #expect(OpenAIEngine.estimateTokens(["role": "user", "content": "hello"]) < 20)
    }

    @Test("Trimming stubs an older image message and leaves the latest turn's images intact")
    func trimStubsOldImages() {
        var messages: [JSONValue] = [
            ["role": "system", "content": "sys"],
            ["role": "user", "content": "go"],
            ["role": "assistant", "content": "", "tool_calls": []],
            ["role": "tool", "tool_call_id": "c1", "content": "[image 1: image/png]\n[image 2: image/jpeg]"],
            OpenAIEngine.imageMessage(toolName: "t", images: images),
            ["role": "assistant", "content": "", "tool_calls": []],
            ["role": "tool", "tool_call_id": "c2", "content": "[image 1: image/png]\n[image 2: image/jpeg]"],
            OpenAIEngine.imageMessage(toolName: "t", images: images),
        ]
        let imageMessages = [
            4: OpenAIEngine.ImageMessageInfo(toolName: "t", count: 2),
            7: OpenAIEngine.ImageMessageInfo(toolName: "t", count: 2),
        ]
        let toolNames = ["c1": "t", "c2": "t"]

        let stubbed = OpenAIEngine.trim(messages: &messages, imageMessages: imageMessages, toolNames: toolNames,
                                        aggressively: false, target: 1_000, projected: 5_000)
        #expect(stubbed == 1)
        #expect(messages[4]["content"]?.string == "[Earlier 2 image(s) from t omitted to fit the context window]")
        #expect(messages[4]["role"]?.string == "user")
        #expect(messages[7]["content"]?.array?.count == 3)
        #expect(messages[3]["content"]?.string == "[image 1: image/png]\n[image 2: image/jpeg]")

        // A second, aggressive pass never re-stubs the stub and still leaves the latest turn alone.
        let again = OpenAIEngine.trim(messages: &messages, imageMessages: imageMessages, toolNames: toolNames, aggressively: true)
        #expect(again == 0)
        #expect(messages[4]["content"]?.string == "[Earlier 2 image(s) from t omitted to fit the context window]")
        #expect(messages[7]["content"]?.array?.count == 3)
    }

    @Test("Trimming stops once the projected size is under the target")
    func trimStopsAtTarget() {
        var messages: [JSONValue] = [
            ["role": "user", "content": "go"],
            ["role": "assistant", "content": "", "tool_calls": []],
            ["role": "tool", "tool_call_id": "c1", "content": "[image 1: image/png]"],
            OpenAIEngine.imageMessage(toolName: "t", images: images),
            ["role": "assistant", "content": "", "tool_calls": []],
            ["role": "tool", "tool_call_id": "c2", "content": "[image 1: image/png]"],
            OpenAIEngine.imageMessage(toolName: "t", images: images),
            ["role": "assistant", "content": "done"],
        ]
        let imageMessages = [3: OpenAIEngine.ImageMessageInfo(toolName: "t", count: 2), 6: OpenAIEngine.ImageMessageInfo(toolName: "t", count: 2)]
        let stubbed = OpenAIEngine.trim(messages: &messages, imageMessages: imageMessages, toolNames: [:],
                                        aggressively: false, target: 4_000, projected: 6_000)
        #expect(stubbed == 1)
        #expect(messages[3]["content"]?.string != nil)
        #expect(messages[6]["content"]?.array != nil)
    }

    @Test("Only 400/422 bodies that blame images or the content shape count as an image rejection")
    func imageRejectionDetection() {
        #expect(OpenAIEngine.isImageRejection(OpenAICompatibleError.http(400, "This model does not support images")))
        #expect(OpenAIEngine.isImageRejection(OpenAICompatibleError.http(400, "Model has no vision capability")))
        #expect(OpenAIEngine.isImageRejection(OpenAICompatibleError.http(422, "Invalid 'messages[3].content': expected a string")))
        #expect(OpenAIEngine.isImageRejection(OpenAICompatibleError.http(400, "image_url is not supported")))
        #expect(!OpenAIEngine.isImageRejection(OpenAICompatibleError.http(500, "image")))
        #expect(!OpenAIEngine.isImageRejection(OpenAICompatibleError.http(400, "context length exceeded")))
        #expect(!OpenAIEngine.isImageRejection(OpenAICompatibleError.server("image")))
    }

    @Test("A refused image message becomes a plain text description")
    func textOnlyImageMessage() {
        let message = OpenAIEngine.textOnlyImageMessage(OpenAIEngine.ImageMessageInfo(toolName: "t", count: 2))
        #expect(message["role"]?.string == "user")
        #expect(message["content"]?.string == "[2 image(s) returned by t are not shown: this model does not accept images]")
    }
}
