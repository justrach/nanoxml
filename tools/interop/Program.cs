// 1:1 interop harness against the real Microsoft Open XML SDK
// (DocumentFormat.OpenXml — the published package of dotnet/Open-XML-SDK).
//
//   interop create <dir>          create sdk.docx / sdk.xlsx / sdk.pptx with the SDK
//   interop verify <file>         open with the SDK, run OpenXmlValidator, print content
//   interop bench  <xlsx> <iters> stream-read every cell -> CSV (SDK's fastest path)
//
// verify exits 0 only when Microsoft's own validator reports zero errors —
// that is the referee for nanoxml-created and nanoxml-round-tripped files.

using System.Diagnostics;
using System.Text;
using DocumentFormat.OpenXml;
using DocumentFormat.OpenXml.Packaging;
using DocumentFormat.OpenXml.Validation;
using A = DocumentFormat.OpenXml.Drawing;
using P = DocumentFormat.OpenXml.Presentation;
using S = DocumentFormat.OpenXml.Spreadsheet;
using W = DocumentFormat.OpenXml.Wordprocessing;

switch (args.Length > 0 ? args[0] : "")
{
    case "create":
        Create(args[1]);
        break;
    case "verify":
        Environment.Exit(Verify(args[1]));
        break;
    case "bench":
        Bench(args[1], args.Length > 2 ? int.Parse(args[2]) : 3);
        break;
    default:
        Console.Error.WriteLine("usage: interop create <dir> | verify <file> | bench <xlsx> [iters]");
        Environment.Exit(64);
        break;
}

static void Create(string dir)
{
    Directory.CreateDirectory(dir);

    var docxPath = Path.Combine(dir, "sdk.docx");
    using (var doc = WordprocessingDocument.Create(docxPath, WordprocessingDocumentType.Document))
    {
        var main = doc.AddMainDocumentPart();
        main.Document = new W.Document(new W.Body(
            new W.Paragraph(new W.Run(new W.Text("Created by the Microsoft Open XML SDK."))),
            new W.Paragraph(new W.Run(new W.Text("Entities: < & > \" '") { Space = SpaceProcessingModeValues.Preserve })),
            new W.Paragraph(
                new W.Run(new W.RunProperties(new W.Bold()), new W.Text("Bold run, ")),
                new W.Run(new W.Text("plain tail.") { Space = SpaceProcessingModeValues.Preserve }))));
        main.Document.Save();
        doc.PackageProperties.Title = "SDK interop";
        doc.PackageProperties.Creator = "DocumentFormat.OpenXml 3.3.0";
    }
    Console.WriteLine($"created {docxPath}");

    var xlsxPath = Path.Combine(dir, "sdk.xlsx");
    using (var ss = SpreadsheetDocument.Create(xlsxPath, SpreadsheetDocumentType.Workbook))
    {
        var wb = ss.AddWorkbookPart();
        wb.Workbook = new S.Workbook();

        var sst = wb.AddNewPart<SharedStringTablePart>();
        sst.SharedStringTable = new S.SharedStringTable(
            new S.SharedStringItem(new S.Text("hello shared")),
            new S.SharedStringItem(new S.Text("comma, \"quoted\"")));
        sst.SharedStringTable.Save();

        var ws = wb.AddNewPart<WorksheetPart>();
        ws.Worksheet = new S.Worksheet(new S.SheetData(
            new S.Row(
                new S.Cell { CellReference = "A1", DataType = S.CellValues.SharedString, CellValue = new S.CellValue("0") },
                new S.Cell { CellReference = "B1", CellValue = new S.CellValue("42") },
                new S.Cell { CellReference = "D1", DataType = S.CellValues.InlineString, InlineString = new S.InlineString(new S.Text("inline")) })
            { RowIndex = 1 },
            new S.Row(
                new S.Cell { CellReference = "A2", DataType = S.CellValues.SharedString, CellValue = new S.CellValue("1") },
                new S.Cell { CellReference = "B2", DataType = S.CellValues.Boolean, CellValue = new S.CellValue("1") })
            { RowIndex = 2 }));
        ws.Worksheet.Save();

        wb.Workbook.AppendChild(new S.Sheets(new S.Sheet
        {
            Id = wb.GetIdOfPart(ws),
            SheetId = 1U,
            Name = "FromSDK",
        }));
        wb.Workbook.Save();
    }
    Console.WriteLine($"created {xlsxPath}");

    var pptxPath = Path.Combine(dir, "sdk.pptx");
    using (var p = PresentationDocument.Create(pptxPath, PresentationDocumentType.Presentation))
    {
        var pp = p.AddPresentationPart();
        pp.Presentation = new P.Presentation();

        var slide = pp.AddNewPart<SlidePart>();
        slide.Slide = new P.Slide(new P.CommonSlideData(new P.ShapeTree(
            new P.NonVisualGroupShapeProperties(
                new P.NonVisualDrawingProperties { Id = 1U, Name = "" },
                new P.NonVisualGroupShapeDrawingProperties(),
                new P.ApplicationNonVisualDrawingProperties()),
            new P.GroupShapeProperties(new A.TransformGroup()),
            new P.Shape(
                new P.NonVisualShapeProperties(
                    new P.NonVisualDrawingProperties { Id = 2U, Name = "Title" },
                    new P.NonVisualShapeDrawingProperties(),
                    new P.ApplicationNonVisualDrawingProperties()),
                new P.ShapeProperties(),
                new P.TextBody(
                    new A.BodyProperties(),
                    new A.ListStyle(),
                    new A.Paragraph(new A.Run(new A.Text("Hello from the SDK"))))))));

        pp.Presentation.AppendChild(new P.SlideIdList(new P.SlideId
        {
            Id = 256U,
            RelationshipId = pp.GetIdOfPart(slide),
        }));
        pp.Presentation.Save();
    }
    Console.WriteLine($"created {pptxPath}");
}

static int Verify(string file)
{
    var validator = new OpenXmlValidator(FileFormatVersions.Office2019);

    // Print + count inside the document's lifetime: ValidationErrorInfo.Part
    // is live-bound to the open package.
    static int Report(IEnumerable<ValidationErrorInfo> errors)
    {
        int n = 0;
        foreach (var e in errors)
        {
            Console.WriteLine($"  [{e.ErrorType}] {e.Part?.Uri} :: {e.Description}");
            n++;
        }
        Console.WriteLine($"ERRORS: {n}");
        return n;
    }

    int n;
    switch (Path.GetExtension(file).ToLowerInvariant())
    {
        case ".docx":
        {
            using var doc = WordprocessingDocument.Open(file, false);
            Console.WriteLine($"text: {doc.MainDocumentPart.Document.InnerText}");
            Console.WriteLine($"title: {doc.PackageProperties.Title} | creator: {doc.PackageProperties.Creator}");
            n = Report(validator.Validate(doc));
            break;
        }
        case ".xlsx":
        {
            using var ss = SpreadsheetDocument.Open(file, false);
            var wb = ss.WorkbookPart;
            var cells = wb.WorksheetParts.SelectMany(p => p.Worksheet.Descendants<S.Cell>()).Count();
            var sheetNames = string.Join(",", wb.Workbook.Descendants<S.Sheet>().Select(s => (string)s.Name));
            Console.WriteLine($"sheets: {sheetNames} | cells: {cells}");
            n = Report(validator.Validate(ss));
            break;
        }
        case ".pptx":
        {
            using var p = PresentationDocument.Open(file, false);
            var texts = p.PresentationPart.SlideParts.Select(sp => sp.Slide.InnerText);
            Console.WriteLine($"slides: {p.PresentationPart.SlideParts.Count()} | text: {string.Join(" / ", texts)}");
            n = Report(validator.Validate(p));
            break;
        }
        default:
            Console.Error.WriteLine($"unsupported extension: {file}");
            return 64;
    }

    return n == 0 ? 0 : 2;
}

static void Bench(string path, int iters)
{
    byte[] bytes = File.ReadAllBytes(path);
    Console.WriteLine($"DocumentFormat.OpenXml 3.3.0 streaming read: {path} ({bytes.Length} bytes zip), {iters} iters + warmup");

    double best = double.MaxValue;
    long sink = 0;
    for (int it = 0; it <= iters; it++)
    {
        var sw = Stopwatch.StartNew();
        using var ms = new MemoryStream(bytes, false);
        using var doc = SpreadsheetDocument.Open(ms, false);
        var wb = doc.WorkbookPart;

        // Shared strings (streamed, same as nanoxml's typed layer does).
        string[] sst = [];
        if (wb.SharedStringTablePart is { } sstPart)
        {
            var list = new List<string>(1024);
            using var r = OpenXmlReader.Create(sstPart);
            while (r.Read())
            {
                if (r.ElementType == typeof(S.SharedStringItem) && r.IsStartElement)
                    list.Add(r.LoadCurrentElement().InnerText);
            }
            sst = list.ToArray();
        }

        // Every worksheet -> CSV with gap preservation + quoting, mirroring
        // `nanoxml bench full`. OpenXmlReader is the SDK's fastest read path.
        var sb = new StringBuilder(1 << 22);
        foreach (var wsPart in wb.WorksheetParts)
        {
            using var r = OpenXmlReader.Create(wsPart);
            string cellType = null;
            int col = 0;
            bool firstInRow = true;
            while (r.Read())
            {
                if (r.ElementType == typeof(S.Row))
                {
                    if (r.IsStartElement) { col = 0; firstInRow = true; }
                    else sb.Append('\n');
                }
                else if (r.ElementType == typeof(S.Cell) && r.IsStartElement)
                {
                    cellType = null;
                    string cref = null;
                    foreach (var a in r.Attributes)
                    {
                        if (a.LocalName == "t") cellType = a.Value;
                        else if (a.LocalName == "r") cref = a.Value;
                    }
                    int target = cref != null ? ColFromRef(cref) : col;
                    if (!firstInRow) sb.Append(',');
                    for (; col < target; col++) sb.Append(',');
                    firstInRow = false;
                    col = target + 1;
                }
                else if (r.ElementType == typeof(S.CellValue) && r.IsStartElement)
                {
                    string text = r.GetText();
                    string val = cellType switch
                    {
                        "s" => sst[int.Parse(text)],
                        "b" => text == "1" ? "TRUE" : "FALSE",
                        _ => text,
                    };
                    CsvAppend(sb, val);
                }
                else if (r.ElementType == typeof(S.Text) && r.IsStartElement && cellType == "inlineStr")
                {
                    // <c t="inlineStr"><is><t>…</t></is></c>
                    CsvAppend(sb, r.GetText());
                }
            }
        }

        sink += sb.Length;
        sw.Stop();
        double t = sw.Elapsed.TotalMilliseconds;
        Console.WriteLine($"  iter {it}: {t:F1} ms{(it == 0 ? " (warmup, JIT)" : "")}");
        if (it > 0 && t < best) best = t;
    }
    Console.WriteLine($"best: {best:F1} ms  (csv chars/iter: {sink / (iters + 1)})");
}
static int ColFromRef(string cref)
{
    int col = 0;
    foreach (char c in cref)
    {
        if (c >= 'A' && c <= 'Z') col = col * 26 + (c - 'A' + 1);
        else break;
    }
    return col - 1;
}

static void CsvAppend(StringBuilder sb, string v)
{
    if (v.IndexOfAny([',', '"', '\n']) < 0)
    {
        sb.Append(v);
        return;
    }
    sb.Append('"');
    foreach (char c in v)
    {
        if (c == '"') sb.Append('"');
        sb.Append(c);
    }
    sb.Append('"');
}
