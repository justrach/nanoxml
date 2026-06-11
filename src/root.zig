//! nanoxml — Office Open XML (docx/xlsx/pptx) reading for Zig.
//!
//! A from-scratch port of the ideas in dotnet/Open-XML-SDK, layered the same
//! way but built for speed: zero-copy slices, SIMD scanning, one arena per
//! package.
//!
//!   zip   — the ZIP container           (~ System.IO.Packaging zip layer)
//!   opc   — content types + rels        (~ System.IO.Packaging)
//!   xml   — streaming pull parser       (~ OpenXmlReader)
//!   ooxml — typed document access       (~ WordprocessingDocument & co.)

pub const zip = @import("zip.zig");
pub const xml = @import("xml.zig");
pub const dom = @import("dom.zig");
pub const opc = @import("opc.zig");
pub const ooxml = @import("ooxml.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
