import Foundation
import ImageIO

/// Reads xmp:Rating and xmpDM:pick from sidecars and image files. Never writes.
nonisolated enum XMPReader {
    enum ReadError: Error, Equatable {
        case notValidXMP
        case notAJPEG
        case truncated
        case notAnImage
    }

    static func value(inSidecar url: URL) throws -> PhotoValue {
        try value(inXMP: Data(contentsOf: url))
    }

    /// Walks the JPEG's header segments, so only the header is read from disk, not the image.
    static func value(inJPEG url: URL) throws -> PhotoValue {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }

        guard try read(2, from: file) == Data([0xFF, 0xD8]) else { throw ReadError.notAJPEG }
        let xmpIdentifier = Data("http://ns.adobe.com/xap/1.0/\0".utf8)

        while true {
            var marker = try readByte(from: file)
            guard marker == 0xFF else { throw ReadError.notAJPEG }
            while marker == 0xFF { marker = try readByte(from: file) }

            if marker == 0xD9 || marker == 0xDA { return .empty }  // end of file, start of image data
            if marker == 0x01 || (0xD0...0xD8).contains(marker) { continue }  // no length

            let lengthBytes = try read(2, from: file)
            let length = Int(lengthBytes[lengthBytes.startIndex]) << 8 | Int(lengthBytes[lengthBytes.startIndex + 1])
            guard length >= 2 else { throw ReadError.notAJPEG }
            let segmentEnd = try file.offset() + UInt64(length - 2)

            if marker == 0xE1, length - 2 > xmpIdentifier.count {
                let identifier = try read(xmpIdentifier.count, from: file)
                if identifier == xmpIdentifier {
                    return try value(inXMP: read(length - 2 - xmpIdentifier.count, from: file))
                }
            }
            try file.seek(toOffset: segmentEnd)
        }
    }

    /// HEIC, PNG and TIFF: the same fields, found through ImageIO (SPEC 5.1, untested with Photomator).
    static func value(inImage url: URL) throws -> PhotoValue {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ReadError.notAnImage
        }
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let xmp = CGImageMetadataCreateXMPData(metadata, nil) else {
            return .empty
        }
        return try value(inXMP: xmp as Data)
    }

    static func value(inXMP data: Data) throws -> PhotoValue {
        // Some camera JPGs end their XMP with a NUL byte, which the XML parser refuses.
        var xml = data
        while xml.last == 0 { xml.removeLast() }

        let handler = XMPHandler()
        let parser = XMLParser(data: xml)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.delegate = handler
        guard parser.parse(), handler.sawRDF else { throw ReadError.notValidXMP }
        return handler.value
    }

    private static func read(_ count: Int, from file: FileHandle) throws -> Data {
        guard let data = try file.read(upToCount: count), data.count == count else {
            throw ReadError.truncated
        }
        return data
    }

    private static func readByte(from file: FileHandle) throws -> UInt8 {
        try read(1, from: file)[0]
    }
}

/// Takes the two fields only from the top level of an rdf:Description, in either form:
/// `xmp:Rating="3"` or `<xmp:Rating>3</xmp:Rating>`. Nested fields of the same name are ignored.
private nonisolated final class XMPHandler: NSObject, XMLParserDelegate {
    private static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    private static let xmp = "http://ns.adobe.com/xap/1.0/"
    private static let xmpDM = "http://ns.adobe.com/xmp/1.0/DynamicMedia/"

    private(set) var value = PhotoValue.empty
    private(set) var sawRDF = false

    private var prefixes: [String: String] = [:]
    private var path: [String] = []
    private var text = ""

    private var isInsideTopDescription: Bool {
        path.count >= 2 && path[path.count - 1] == Self.rdf + "Description"
            && path[path.count - 2] == Self.rdf + "RDF"
    }

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        prefixes[prefix] = namespaceURI
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        path.append((namespaceURI ?? "") + elementName)
        text = ""
        if path.last == Self.rdf + "RDF" { sawRDF = true }
        guard isInsideTopDescription else { return }

        for (name, attributeValue) in attributeDict {
            let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let uri = prefixes[parts[0]] else { continue }
            store(attributeValue, field: uri + parts[1])
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
    ) {
        let field = path.removeLast()
        if isInsideTopDescription { store(text, field: field) }
        text = ""
    }

    private func store(_ raw: String, field: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch field {
        case Self.xmp + "Rating":
            if let number = Double(trimmed), let stars = Int(exactly: number), (0...5).contains(stars) {
                value.stars = stars
            }
        case Self.xmpDM + "pick":
            if let number = Int(trimmed), let flag = Flag(rawValue: number) {
                value.flag = flag
            }
        default:
            break
        }
    }
}
