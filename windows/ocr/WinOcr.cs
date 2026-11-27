using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using Windows.Data.Pdf;
using Windows.Globalization;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage;
using Windows.Storage.Streams;

internal static class WinOcr
{
    private static readonly MethodInfo[] AwaitMethods = typeof(WindowsRuntimeSystemExtensions).GetMethods()
        .Where(method => method.Name == "AsTask" && method.GetParameters().Length == 1).ToArray();
    private static readonly MethodInfo AwaitValue = AwaitMethods.Single(method => method.IsGenericMethodDefinition &&
        method.GetParameters()[0].ParameterType.Name == "IAsyncOperation`1");
    private static readonly MethodInfo AwaitAction = AwaitMethods.Single(method => !method.IsGenericMethod &&
        method.GetParameters()[0].ParameterType.Name == "IAsyncAction");

    // The inbox .NET Framework facade refers to the aggregate Windows.winmd identity.
    // Windows distributes separate metadata files on SDK-free build hosts.
    private static Task<T> Value<T>(object operation)
    {
        return (Task<T>)AwaitValue.MakeGenericMethod(typeof(T)).Invoke(null, new[] { operation });
    }

    private static Task Action(object operation)
    {
        return (Task)AwaitAction.Invoke(null, new[] { operation });
    }

    public sealed class Request
    {
        public string operation { get; set; }
        public string path { get; set; }
        public string[] languages { get; set; }
        public string renderDirectory { get; set; }
        public bool pdf { get; set; }
        public int maxPages { get; set; }
    }

    public sealed class Page
    {
        public int page { get; set; }
        public string error { get; set; }
        public string text { get; set; }
        public object[] lines { get; set; }
        public string language { get; set; }
        public int width { get; set; }
        public int height { get; set; }
        public double pageWidth { get; set; }
        public double pageHeight { get; set; }
        public double elapsedSeconds { get; set; }
        public bool rasterAvailable { get; set; }
    }

    private static int Main()
    {
        Console.InputEncoding = new UTF8Encoding(false);
        Console.OutputEncoding = new UTF8Encoding(false);
        var json = new JavaScriptSerializer { MaxJsonLength = 24 * 1024 * 1024 };
        try
        {
            var request = json.Deserialize<Request>(Console.In.ReadToEnd());
            object result;
            if (request.operation == "languages")
            {
                result = new
                {
                    languages = OcrEngine.AvailableRecognizerLanguages.Select(language => language.LanguageTag).ToArray(),
                    maxDimension = OcrEngine.MaxImageDimension
                };
            }
            else if (request.operation == "recognize")
            {
                result = Recognize(request).GetAwaiter().GetResult();
            }
            else
            {
                throw new InvalidDataException("OCR_INVALID_REQUEST");
            }
            Console.WriteLine(json.Serialize(result));
            return 0;
        }
        catch (InvalidDataException error)
        {
            Console.WriteLine(json.Serialize(new { error = error.Message }));
            return 2;
        }
        catch (Exception)
        {
            Console.WriteLine(json.Serialize(new { error = "OCR_READ_FAILED" }));
            return 2;
        }
    }

    private static List<OcrEngine> Engines(string[] tags)
    {
        var engines = new List<OcrEngine>();
        if (tags == null || tags.Length == 0)
        {
            var engine = OcrEngine.TryCreateFromUserProfileLanguages();
            if (engine == null) throw new InvalidDataException("OCR_LANGUAGE_MISSING");
            engines.Add(engine);
            return engines;
        }
        foreach (string sourceTag in tags)
        {
            var tag = sourceTag;
            if (tag == "zh-Hans" || tag == "zh-Hans-CN") tag = "zh-CN";
            if (tag == "zh-Hant" || tag == "zh-Hant-TW") tag = "zh-TW";
            var engine = OcrEngine.TryCreateFromLanguage(new Language(tag));
            if (engine == null) throw new InvalidDataException("OCR_LANGUAGE_MISSING:" + sourceTag);
            engines.Add(engine);
        }
        return engines;
    }

    private static async Task<object> Recognize(Request request)
    {
        var engines = Engines(request.languages);
        var file = await Value<StorageFile>(StorageFile.GetFileFromPathAsync(request.path));
        var pages = new List<Page>();
        if (!request.pdf)
        {
            using (var stream = await Value<IRandomAccessStream>(file.OpenAsync(FileAccessMode.Read)))
                pages.Add(await ReadPage(stream, 1, engines));
            return new { pages = pages };
        }

        var document = await Value<PdfDocument>(PdfDocument.LoadFromFileAsync(file));
        if (document.PageCount == 0 || document.PageCount > request.maxPages)
            throw new InvalidDataException("OCR_PAGE_LIMIT");
        ulong rasterBytes = 0;
        for (uint index = 0; index < document.PageCount; index++)
        {
            int number = (int)index + 1;
            try
            {
                using (var page = document.GetPage(index))
                using (var stream = new InMemoryRandomAccessStream())
                {
                    var size = page.Size;
                    double scale = Math.Min(1.5, Math.Min(OcrEngine.MaxImageDimension / Math.Max(size.Width, size.Height),
                        Math.Sqrt(12000000 / (size.Width * (double)size.Height))));
                    var options = new PdfPageRenderOptions
                    {
                        BitmapEncoderId = BitmapEncoder.PngEncoderId,
                        DestinationWidth = (uint)Math.Max(1, Math.Floor(size.Width * scale)),
                        DestinationHeight = (uint)Math.Max(1, Math.Floor(size.Height * scale))
                    };
                    await Action(page.RenderToStreamAsync(stream, options));
                    stream.Seek(0);
                    var result = await ReadPage(stream, number, engines);
                    result.pageWidth = size.Width * 0.75;
                    result.pageHeight = size.Height * 0.75;
                    if (!String.IsNullOrEmpty(request.renderDirectory) && rasterBytes + stream.Size <= 128 * 1024 * 1024)
                    {
                        rasterBytes += stream.Size;
                        stream.Seek(0);
                        using (var reader = new DataReader(stream))
                        {
                            var length = await Value<uint>(reader.LoadAsync((uint)stream.Size));
                            var bytes = new byte[length];
                            reader.ReadBytes(bytes);
                            using (var output = File.Open(Path.Combine(request.renderDirectory, "page-" + number + ".png"), FileMode.CreateNew))
                                output.Write(bytes, 0, bytes.Length);
                        }
                        result.rasterAvailable = true;
                    }
                    pages.Add(result);
                }
            }
            catch (Exception)
            {
                pages.Add(new Page { page = number, error = "PDF_PAGE_FAILED", lines = new object[0], text = "" });
            }
        }
        return new { pages = pages };
    }

    private static async Task<Page> ReadPage(IRandomAccessStream stream, int page, List<OcrEngine> engines)
    {
        var timer = Stopwatch.StartNew();
        var decoder = await Value<BitmapDecoder>(BitmapDecoder.CreateAsync(stream));
        using (var bitmap = await Value<SoftwareBitmap>(decoder.GetSoftwareBitmapAsync()))
        {
            if (bitmap.PixelWidth > OcrEngine.MaxImageDimension || bitmap.PixelHeight > OcrEngine.MaxImageDimension)
                throw new InvalidDataException("OCR_DIMENSION_LIMIT");
            OcrResult selected = null;
            string language = null;
            int bestLength = -1;
            foreach (var engine in engines)
            {
                var result = await Value<OcrResult>(engine.RecognizeAsync(bitmap));
                int length = result.Text.Count(character => !Char.IsWhiteSpace(character));
                if (length <= bestLength) continue;
                selected = result;
                language = engine.RecognizerLanguage.LanguageTag;
                bestLength = length;
            }
            return new Page
            {
                page = page,
                text = String.Join("\n", selected.Lines.Select(line => line.Text)),
                lines = selected.Lines.Select(line => new
                {
                    text = line.Text,
                    words = line.Words.Select(word => new
                    {
                        text = word.Text, x = word.BoundingRect.X, y = word.BoundingRect.Y,
                        width = word.BoundingRect.Width, height = word.BoundingRect.Height
                    }).ToArray()
                }).ToArray(),
                language = language,
                width = bitmap.PixelWidth,
                height = bitmap.PixelHeight,
                elapsedSeconds = timer.Elapsed.TotalSeconds
            };
        }
    }
}
