import Foundation

/// A folder of made-up files, removed by the caller with remove().
struct TemporaryFolder {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("RatingmatorTests-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func write(_ data: Data, to relativePath: String) throws -> URL {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

enum Sample {
    /// A sidecar in the element form Photomator writes.
    static func sidecar(rating: Int? = nil, pick: Int? = nil) -> Data {
        var fields = ""
        if let rating { fields += "<xmp:Rating>\(rating)</xmp:Rating>" }
        if let pick { fields += "<xmpDM:pick>\(pick)</xmpDM:pick>" }
        return Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/"
             xmlns:xmpDM="http://ns.adobe.com/xmp/1.0/DynamicMedia/">\(fields)</rdf:Description>
            </rdf:RDF></x:xmpmeta>
            """.utf8)
    }

    /// The attribute form, as in many of the JPGs.
    static func attributeXMP(rating: Int, pick: Int) -> Data {
        Data("""
            <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/"
             xmlns:xmpDM="http://ns.adobe.com/xmp/1.0/DynamicMedia/" xmp:Rating="\(rating)" xmpDM:pick="\(pick)"/>
            </rdf:RDF></x:xmpmeta><?xpacket end="w"?>
            """.utf8)
    }

    /// The header of a JPEG: an Exif segment, then the XMP segment if given, then the start of image data.
    static func jpeg(xmp: Data? = nil) -> Data {
        func segment(_ marker: UInt8, _ payload: Data) -> Data {
            let length = payload.count + 2
            return Data([0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)]) + payload
        }
        var data = Data([0xFF, 0xD8])
        data += segment(0xE1, Data("Exif\0\0not really exif".utf8))
        if let xmp {
            data += segment(0xE1, Data("http://ns.adobe.com/xap/1.0/\0".utf8) + xmp)
        }
        data += Data([0xFF, 0xDA, 0x00, 0x02, 0x12, 0x34])
        return data
    }
}
