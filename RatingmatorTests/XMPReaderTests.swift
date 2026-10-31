import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Ratingmator

struct XMPReaderTests {
    @Test func readsTheElementForm() throws {
        let value = try XMPReader.value(inXMP: Sample.sidecar(rating: 4, pick: -1))
        #expect(value == PhotoValue(stars: 4, flag: .reject))
    }

    @Test func readsTheAttributeForm() throws {
        let value = try XMPReader.value(inXMP: Sample.attributeXMP(rating: 2, pick: 1))
        #expect(value == PhotoValue(stars: 2, flag: .pick))
    }

    @Test func anExplicitZeroIsAValue() throws {
        let value = try XMPReader.value(inXMP: Sample.sidecar(rating: 0, pick: 0))
        #expect(value == PhotoValue(stars: 0, flag: Flag.none))
    }

    @Test func aMissingFieldIsNoValue() throws {
        #expect(try XMPReader.value(inXMP: Sample.sidecar()) == .empty)
        #expect(try XMPReader.value(inXMP: Sample.sidecar(rating: 3)) == PhotoValue(stars: 3, flag: nil))
    }

    @Test func aValueOutOfRangeIsNoValue() throws {
        #expect(try XMPReader.value(inXMP: Sample.sidecar(rating: -1, pick: 7)) == .empty)
    }

    @Test func aDifferentPrefixForTheSameNamespaceWorks() throws {
        let xmp = Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><r:RDF xmlns:r="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <r:Description xmlns:basic="http://ns.adobe.com/xap/1.0/" basic:Rating="5"/></r:RDF></x:xmpmeta>
            """.utf8)
        #expect(try XMPReader.value(inXMP: xmp) == PhotoValue(stars: 5, flag: nil))
    }

    @Test func aNestedFieldOfTheSameNameIsIgnored() throws {
        let xmp = Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:o="urn:other">
            <o:Derived rdf:parseType="Resource"><xmp:Rating>5</xmp:Rating></o:Derived>
            </rdf:Description></rdf:RDF></x:xmpmeta>
            """.utf8)
        #expect(try XMPReader.value(inXMP: xmp) == .empty)
    }

    /// Phone JPGs hold this: valid XMP with nothing in it.
    @Test func anEmptyRDFHasNoValue() throws {
        let xmp = Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 5.1.2">
            <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"/></x:xmpmeta>
            """.utf8)
        #expect(try XMPReader.value(inXMP: xmp) == .empty)
    }

    @Test func aTrailingNULByteIsAccepted() throws {
        let xmp = Sample.attributeXMP(rating: 2, pick: 0) + Data([0])
        #expect(try XMPReader.value(inXMP: xmp) == PhotoValue(stars: 2, flag: Flag.none))
    }

    @Test func damagedOrForeignXMLIsRefused() {
        #expect(throws: XMPReader.ReadError.notValidXMP) {
            try XMPReader.value(inXMP: Data("<x:xmpmeta><rdf:RDF".utf8))
        }
        #expect(throws: XMPReader.ReadError.notValidXMP) {
            try XMPReader.value(inXMP: Data("<something>else</something>".utf8))
        }
        #expect(throws: XMPReader.ReadError.notValidXMP) {
            try XMPReader.value(inXMP: Data())
        }
    }

    @Test func readsAJPEG() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = try folder.write(Sample.jpeg(xmp: Sample.attributeXMP(rating: 3, pick: 1)), to: "a.JPG")
        #expect(try XMPReader.value(inJPEG: file) == PhotoValue(stars: 3, flag: .pick))
    }

    @Test func aJPEGWithoutXMPHasNoValue() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = try folder.write(Sample.jpeg(), to: "a.JPG")
        #expect(try XMPReader.value(inJPEG: file) == .empty)
    }

    @Test func refusesAFileThatIsNoJPEG() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = try folder.write(Data("not a jpeg".utf8), to: "a.JPG")
        #expect(throws: XMPReader.ReadError.notAJPEG) {
            try XMPReader.value(inJPEG: file)
        }
    }

    @Test func refusesATruncatedJPEG() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let whole = Sample.jpeg(xmp: Sample.sidecar(rating: 1))
        let file = try folder.write(whole.prefix(whole.count / 2), to: "a.JPG")
        #expect(throws: XMPReader.ReadError.truncated) {
            try XMPReader.value(inJPEG: file)
        }
    }

    @Test(arguments: [("a.png", "public.png"), ("a.tif", "public.tiff"), ("a.heic", "public.heic")])
    func readsOtherImageTypes(name: String, type: String) throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let url = folder.url.appendingPathComponent(name)

        let context = try #require(CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let image = try #require(context.makeImage())
        let metadata = CGImageMetadataCreateMutable()
        #expect(CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, "3" as CFString))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        CGImageDestinationAddImageAndMetadata(destination, image, metadata, nil)
        #expect(CGImageDestinationFinalize(destination))

        #expect(try XMPReader.value(inImage: url).stars == 3)
    }

    @Test func refusesAnImageThatIsNone() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = try folder.write(Data("not an image".utf8), to: "a.png")
        #expect(throws: XMPReader.ReadError.notAnImage) {
            try XMPReader.value(inImage: file)
        }
    }
}
