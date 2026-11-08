import XCTest
@testable import PigiCore

final class InlineImageTests: XCTestCase {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    private let gif = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!

    func testNamelessCIDImageIsKeptAndRewrittenWithoutTouchingRemoteURLs() {
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"><script>alert(1)</script></svg>".utf8)
        let raw = """
        Content-Type: multipart/related; boundary="related-boundary"

        --related-boundary
        Content-Type: text/html; charset=utf-8

        <p>Hi</p><img src="cid:Pixel%40Example.Test"><img src='cid:other@example.test'><img src="cid:dot@example.test"><img src="https://tracker.example/a.png"><span>acid:Pixel@Example.Test</span>
        <div style="background:url(cid:pixel@example.test)"></div>
        --related-boundary
        Content-Type: image/png
        Content-ID: <Pixel@Example.Test>
        Content-Transfer-Encoding: base64

        \(png.base64EncodedString())
        --related-boundary
        Content-Type: image/svg+xml
        Content-ID: <other@example.test>
        Content-Transfer-Encoding: base64

        \(svg.base64EncodedString())
        --related-boundary
        Content-Type: image/gif
        Content-Disposition: attachment; filename="dot.gif"
        Content-ID: <dot@example.test>
        Content-Transfer-Encoding: base64

        \(gif.base64EncodedString())
        --related-boundary--
        """
        let mail = MIME.parse(Data(raw.utf8))
        XCTAssertEqual(mail.inlineImages.map(\.contentID), ["pixel@example.test", "other@example.test", "dot@example.test"])
        XCTAssertEqual(mail.inlineImages[0].data, png)
        XCTAssertEqual(mail.attachments.map(\.name), ["inline-pixel@example.test", "inline-other@example.test", "dot.gif"])
        let shown = InlineImages.embed(mail.html, images: mail.inlineImages)
        XCTAssertTrue(shown.contains("data:image/png;base64,"))
        XCTAssertTrue(shown.contains("data:image/gif;base64,"))
        XCTAssertTrue(shown.contains("cid:other@example.test"))
        XCTAssertTrue(shown.contains("https://tracker.example/a.png"))
        XCTAssertTrue(shown.contains("acid:Pixel@Example.Test"))
        XCTAssertFalse(shown.contains("cid:Pixel%40"))
        XCTAssertFalse(shown.contains("cid:dot@example.test"))
        XCTAssertFalse(shown.contains("<script>"))
    }

    func testForwardedRFC822KeepsInnerImageAndAttachedMessageStaysSeparate() throws {
        let forwarded = """
        Content-Type: message/rfc822

        Content-Type: multipart/related; boundary="inner"

        --inner
        Content-Type: text/html

        <img src="cid:a@b">
        --inner
        Content-Type: image/gif
        Content-ID: <a@b>
        Content-Transfer-Encoding: base64

        \(gif.base64EncodedString())
        --inner--
        """
        let parsed = MIME.parse(Data(forwarded.utf8))
        XCTAssertEqual(parsed.html, "<img src=\"cid:a@b\">")
        XCTAssertEqual(parsed.inlineImages.map(\.data), [gif])

        let attached = """
        Content-Type: multipart/mixed; boundary="mix"

        --mix
        Content-Type: text/plain

        hello
        --mix
        Content-Type: message/rfc822
        Content-Disposition: attachment; filename="fwd.eml"

        Content-Type: text/html

        <p>secret forwarded</p>
        --mix--
        """
        let outer = MIME.parse(Data(attached.utf8))
        XCTAssertEqual(outer.text, "hello")
        XCTAssertEqual(outer.html, "")
        XCTAssertEqual(outer.attachments.map(\.name), ["fwd.eml"])
        XCTAssertTrue(outer.inlineImages.isEmpty)
    }

    func testOversizedAndUnsafeImagesAreNotEmbedded() {
        XCTAssertNil(InlineImages.dataURL(mime: "image/svg+xml", data: Data("<svg/>".utf8)))
        XCTAssertNil(InlineImages.dataURL(mime: "image/png", data: Data(count: InlineImages.maxBytes + 1)))
        XCTAssertEqual(
            InlineImages.embed("<img src=\"cid:x\">", images: [MailInlineImage(contentID: "x", mime: "image/svg+xml", data: Data("<svg/>".utf8))]),
            "<img src=\"cid:x\">")
        let huge = Data(count: InlineImages.maxBytes + 1)
        let raw = """
        Content-Type: image/png
        Content-ID: <huge@example.test>
        Content-Transfer-Encoding: base64

        \(huge.base64EncodedString())
        """
        let mail = MIME.parse(Data(raw.utf8))
        XCTAssertTrue(mail.inlineImages.isEmpty)
        XCTAssertEqual(mail.attachments.map(\.name), ["inline-huge@example.test"])
    }
}
