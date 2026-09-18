# Curated catalog, version 1

Authored 2026-09-18. `Short Circuit/Resources/Catalog.json` contains **146 Kinds, 60 unique Common ranks, 162 explicit UTIs, and 16 URL schemes**. All 162 UTIs occur as declarations in the captured Launch Services dump and resolve through `UTType` on this Mac to declared types conforming to `public.item` or `public.data`. No invented or unverified UTI is included. This read-only check establishes content-type eligibility, not successful default-handler writes; no setter was called.

## Sources and ranking judgment

- The editorial brief in `.build/prompts/catalog-content.md` supplies the intended audience and format families. The order is an editorial choice, **not usage telemetry or a ranking inferred from installed app counts**. Browser and mail lead, followed by everyday documents and images, text and office work, structured data and source code, archives and media, then specialized link roles.
- [The project plan](plan.md) supplies the human-level Kind model and the coupled browser role. The catalog calls that Kind **“Web browser”**, retains its stable `web-page` ID, and combines HTML, XHTML, `http`, and `https`. There is no second HTML Kind that could compete with it. “Email” is the `mailto` role; saved `.eml` messages remain separate.
- [Dump format analysis](spikes/dump-format.md), the immutable `.build/dump-truth/dump.txt`, `.build/reports/codex-review-artifacts/parsed-snapshot.json`, and `.build/reports/codex-rereview-artifacts/kinds.json` supply declaration, conformance, extension, and alias evidence. The capture is macOS 26.6.2 (25G83), 2026-09-18T17:38:53.512863 UTC; dump SHA-256 `1153612d5fc59017273f51999dd7e86bed7b80a352131e08ccc78d530d5fdc88`. App names in that evidence identify declaration provenance; they do not select which applications the catalog promotes.
- Apple's [Uniform Type Identifiers documentation](https://developer.apple.com/documentation/uniformtypeidentifiers/) and [file and data type declaration guidance](https://developer.apple.com/documentation/uniformtypeidentifiers/defining-file-and-data-types-for-your-app) provide the type/conformance background. Every selected identifier is independently evidenced by this dump; none depends on an inferred Apple identifier.

Sixty ranks keep Common bounded. A format's presence in the catalog does not guarantee a row on every Mac: it must match claimed content or a registered scheme. DNG is the ranked RAW representative; twenty additional camera-specific RAW Kinds remain searchable without treating different camera formats as aliases. Standalone AAC, ISO images, fonts, FaceTime, SFTP, legacy Office formats, templates, and less frequent encodings are cataloged but unranked. Their omission from Common is a size-budget choice, not a claim that they are unsupported. Another installation can expose different members while retaining the same editorial order.

## Included aliases and format boundaries

The following table exhausts all multi-UTI entries, including every added vendor alias. Evidence means declaration fields in the captured dump, followed by the live content-conformance check. Matching extensions alone are not presented as proof of equivalence. Some entries deliberately include encodings or subtypes of one human format; the table states those boundaries.

| Kind | Explicit identifiers | Reason for grouping |
|---|---|---|
| Web browser | `public.html`, `public.xhtml` | The project's explicit browser-role contract couples these formats with HTTP and HTTPS; this is a role grouping, not a claim that HTML and XHTML are identical syntax. |
| Plain text | `public.plain-text`, `public.utf8-plain-text`, `public.utf16-plain-text`, `public.utf16-external-plain-text`, `com.apple.traditional-mac-plain-text` | All four specific types declare conformance to plain text. These are text encodings, including the Apple legacy encoding, rather than markup formats. Explicit listing does not create a member unless a type is claimed. |
| Word document | `org.openxmlformats.wordprocessingml.document`, `com.microsoft.word.openxmlformats.wordprocessingml.document`, `com.microsoft.word.strictopenxmlformats.wordprocessingml.document`, `org.strictopenxmlformats.wordprocessingml.document` | Microsoft's two identifiers explicitly conform to the standard DOCX type; the strict organization-prefixed declaration is an Open XML composite `.docx` document. Strict and transitional DOCX belong to the requested Word document family. Macro documents, templates, binary DOC, and standalone Word XML do not. |
| Excel spreadsheet | `org.openxmlformats.spreadsheetml.sheet`, `com.microsoft.excel.openxmlformats.spreadsheetml.sheet` | Microsoft's XLSX declaration explicitly conforms to the organization-prefixed XLSX type. |
| Word macro document | `org.openxmlformats.wordprocessingml.document.macroenabled`, `com.microsoft.word.openxmlformats.wordprocessingml.document.macroenabled` | Direct conformance to the matching DOCM type, with the same extension. Kept separate from DOCX. |
| Excel macro spreadsheet | `org.openxmlformats.spreadsheetml.sheet.macroenabled`, `com.microsoft.excel.openxmlformats.spreadsheetml.sheet.macroenabled` | Direct conformance to the matching XLSM type. Kept separate from XLSX and XLSB. |
| Word template | `org.openxmlformats.wordprocessingml.template`, `com.microsoft.word.openxmlformats.wordprocessingml.template` | Direct conformance to the matching DOTX type. |
| Excel template | `org.openxmlformats.spreadsheetml.template`, `com.microsoft.excel.openxmlformats.spreadsheetml.template` | Direct conformance to the matching XLTX type. |
| CSV table | `public.comma-separated-values-text`, `com.araelium.querious.csv` | Querious explicitly declares conformance to the standard CSV type and uses `.csv`. |
| Tab-separated table | `public.tab-separated-values-text`, `com.araelium.querious.tab` | Querious explicitly declares conformance to the standard tab-separated type; `.tab` and `.tsv` are alternative extensions here. |
| CSS stylesheet | `public.css`, `com.blackpixel.kaleidoscope.css` | Kaleidoscope declares “CSS File,” `.css`, `text/css`, and plain-text conformance. Those specific semantics support the stylesheet alias despite the absence of a direct `public.css` supertype. |
| SQL source | `org.iso.sql`, `com.araelium.querious.sql` | Querious explicitly conforms to `org.iso.sql`; its `.mysql` extension is included alongside `.sql` and `.psql`. SQL dialects are one source-file family, not executable databases. |
| C++ header | `public.c-plus-plus-header`, `public.c-plus-plus-inline-header` | The `.inl` type explicitly conforms to the C++ header type. C headers and C++ implementation sources remain separate. |
| Property list | `com.apple.property-list`, `com.apple.xml-property-list`, `com.apple.binary-property-list`, `com.apple.ascii-property-list` | Apple's three encodings explicitly conform to the property-list type. All are `.plist` data; generic XML remains a different Kind. |
| MPEG-4 audio | `com.apple.m4a-audio`, `public.mpeg-4-audio` | Apple's M4A declaration includes direct conformance to MPEG-4 audio. This groups the audio container family, not a codec: AAC and ALAC can both occur. Standalone `.aac` and movie types remain separate. |
| WAV audio | `public.wav`, `com.microsoft.waveform-audio` | Microsoft's declaration names waveform audio and supplies `.wav` and the specific WAV MIME types; `.wave` and `.bwf` are retained as its declared variants. |
| MPEG-4 video | `public.mpeg-4`, `public.mpeg-4-movie` | Both declare movie conformance and `.mp4`. Explicit audio ownership prevents the shared extension from pulling audio into this Kind. |
| M3U playlist | `public.m3u-playlist`, `com.apple.music.m3u-playlist` | Both declare playlist conformance, `.m3u`/`.m3u8`, and the M3U audio MIME tags. The Apple Music identifier describes the playlist format, not a private application link. |
| EPUB folder | `org.idpf.epub-folder`, `com.apple.ibooks.epub` | Both declare an “Electronic Publication (EPUB)” package with `.epub`, `com.apple.package`, and composite-content conformance; the IDPF declaration additionally identifies the folder MIME type. This is the unpacked EPUB representation, separate from the zipped `org.idpf.epub-container`. |
| TrueType font | `public.truetype-font`, `public.truetype-ttf-font` | The concrete TTF identifier explicitly conforms to TrueType and shares `.ttf`. OpenType `.otf` remains separate. |

Vendor-prefixed **primary** format identifiers are also intentional: PDF, Photoshop/PSB, Illustrator, EPS, GIF, BMP, PICT, Markdown, JavaScript, TypeScript, Java, AppleScript, legacy Office, iWork, QuickTime/M4V, RTFD, disk images/XIP, RAR, OpenEXR, and camera RAW formats often have a vendor namespace rather than a `public.*` identifier. Each is verified, and none is renamed to an invented `public.*` spelling. The [complete UTI provenance table](../.build/reports/catalog-content-artifacts/uti-provenance.tsv) lists every exact identifier, including those primary identifiers, declaration counts, live conformance, and preferred extensions.

Additional explicit boundaries:

- Canon CRW, CR2, CR3, and TIFF RAW; Nikon NEF and NRW; Sony ARW, SRF, and SR2; Fujifilm RAF; Panasonic RAW and RW2; Leica RAW and RWL; Olympus ORF; Pentax PEF; Samsung SRW; Hasselblad 3FR and FFF; Phase One IIQ; and Adobe DNG each have their own Kind. `com.adobe.raw-image` is the dump's concrete `.dng` declaration, not a bucket for all RAW photos.
- Canon's `com.canon.tif-raw-image` has authoritative ownership outside ordinary TIFF. A trial merge otherwise adopted it into TIFF because it shares `.tif`. Panasonic and Leica `.raw` are also explicitly owned separately.
- Radiance and PICT both mention `.pic` but are different image formats. They are separate. HEIC and HEIF are separate, and sequence variants are not explicitly merged into still-image Kinds.
- Modern iWork `.sffpages`, `.sffnumbers`, and `.sffkey` flat-file types get the ranked Pages, Numbers, and Keynote entries. Their earlier `.pages`, `.numbers`, and `.key` package identifiers have separate unranked package Kinds. A shared suffix does not erase the package/file boundary.
- `com.microsoft.word.wordml`, `com.microsoft.word.wordprocessingml`, and `com.microsoft.excel.xml` each get separate unranked entries. Their `.xml` suffix does not make them generic XML or prove that the two Word declarations are identical schemas.
- TypeScript and MPEG transport streams own their respective `.ts` UTIs separately. Gzip versus gzip-compressed TAR, bzip2 versus bzip2-compressed TAR, and XZ versus XZ-compressed TAR remain separate. AIFF and compressed AIFF remain separate.

## Excluded, uncertain, and unverified identifiers

| Identifier or family | Decision and evidence |
|---|---|
| `public.markdown` | Deliberately absent. The hand-test rejected it; the declaration has no supertypes, and the live type conforms to neither item nor data. Markdown uses `net.daringfireball.markdown`. |
| `com.microsoft.outlook15.icalendar` | Its `.ics` declaration identifies iCalendar and a calendar-event supertype, so it is a semantic alias, but its live type conforms to neither item nor data on this Mac. Do not rely on it as a catalog setter target; use `com.apple.ical.ics`. |
| `com.microsoft.outlook15.email-message` | Its `.eml` declaration identifies email-message content, but its live type also fails item/data conformance. Use `com.apple.mail.email`. |
| `com.araelium.querious.sqlite` | The declaration identifies SQLite, but the live type fails item/data conformance. Use `org.sqlite.sqlite`. |
| `org.matroska.mkv` and other guessed Matroska spellings | No MKV UTI or `.mkv` declaration was found in the captured inventory; no Apple system declaration was established. The Matroska entry intentionally has **empty `utis`**, extension `mkv`, and a Common rank. The loader may adopt a future claimed video-compatible `.mkv` type; the entry is dormant on this Mac. This is an extension-based catalog entry, not a fabricated UTI. |
| `com.microsoft.powerpoint.openxmlformats.presentationml.presentation` | Found as a claim without a corresponding declared format in the examined inventory. No explicit alias; use the verified organization-prefixed PPTX type. |
| `org.tukaani.xz-tar-archive` | Claimed spelling is not the verified declaration. The catalog uses the observed `org.tukaani.tar-xz-archive`. |
| `com.olympus.sr-raw-image`, `com.olympus.or-raw-image` | Additional `.orf` variants are not forced into the ordinary ORF entry: exact format equivalence was not established. Runtime adoption remains governed by the loader. |
| `public.tar-archive` versus `org.gnu.gnu-tar-archive` | Only the public TAR type is explicitly included. No forced assertion that every TAR dialect is the same format. |
| `public.cpio-archive` versus `cx.c3.pax-archive` | Neither is included in this initial catalog. A shared `.pax` suffix is insufficient to assert an alias. |
| Apple Mail MBOX packages, Outlook MBOX, Outlook MSG/OLK types | Left to discovery. Folder layout, mailbox file layout, and proprietary Outlook messages must not be equated with EML or one another merely because they concern email. |
| Office BIFF generations, macro templates, iWork `*-tef`/templates, font collections, WOFF/WOFF2, standalone Opus identifiers | Outside this first catalog's size budget or insufficiently verified. No guessed UTI is added. Ogg audio retains the dump's `.opus` tag without asserting a standalone Opus UTI. |
| Broad base types and dynamic types | No `public.item`, `public.data`, generic image/audio/movie type, `com.apple.disk-image`, or `dyn.*` entry. The DMG entry uses concrete `com.apple.disk-image-udif`. |
| `zoommtg`, `vscode`, and other app-owned launch links | Not included. The catalog favors general roles with plausible competing handlers. FaceTime is the specifically requested exception; its two call schemes form an unranked call role. |

The excluded Markdown, Outlook, and Querious identifiers can still be rediscovered by the loader's extension-adoption rule. The integration check confirms that all four remain **`isSettable = false`** when adopted; none is an explicit catalog target. Content alone cannot suppress unknown aliases from discovery, and this task does not alter the loader. Their declarations may also change on another Mac. This distinction is why omission from `utis` is documented separately from runtime membership.

URL scheme roles follow the brief: `mailto`, `tel`, `sms`, `facetime`/`facetime-audio`, `ftp`/`ftps`, `sftp`, `ssh`, `magnet`, `feed`/`rss`, and `webcal`/`webcals`, plus the browser pair. Grouped schemes describe a human role; FTP and SFTP remain separate. A scheme without registered claimants is dormant, not proof of an installed handler. `magnet`, `feed`, `rss`, and `webcals` are not in this capture's claimed scheme list; this does not justify replacing them with app-private schemes.

## Verification and limitations

The production `Catalog.decode` and `KindBuilder` were compiled into a read-only harness with Swift 6, MainActor default isolation, and the project's concurrency setting. Compilation produced no warnings. It loaded all **146 entries** against the immutable parsed capture and produced **932 total Kinds, 135 catalog Kinds, and 56 Common Kinds**. The four ranked entries without a match were Numbers, Matroska, Magnet links, and Feed subscriptions. Other dormant entries were Numbers package, Canon CR3, Leica RAW, Panasonic RAW/RW2, and Sony ARW/SR2. These are valid generalized catalog content rather than promises about this Mac's apps.

Validation checked JSON/schema fields, category values, unique IDs, unique UTI ownership, unique scheme ownership, exact ranks 1–60, declaration provenance, and live type eligibility. Integration assertions checked no stolen explicit members, one merged Kind per explicit alias family, the ambiguous-format boundaries above, and unsettable status for the four runtime-adopted unsupported aliases. It also confirmed that ordinary TIFF no longer absorbs Canon TIFF RAW. [Machine-readable results](../.build/reports/catalog-content-artifacts/validation.json), [merge output](../.build/reports/catalog-content-artifacts/merge.log), and [live type checks](../.build/reports/catalog-content-artifacts/live-types.json) retain the evidence.

No default handler was changed, no live writer or app UI was run, and no claim is made about successful consent or handler writes. This task did not change the loader, shared Kind model, project file, or tests; other agents own those changes. The harness exercises the current in-progress data layer, so aggregate counts can change if that agent subsequently revises discovery. Validation used the saved dump plus live read-only `UTType` lookup, not a fresh inventory of all installed applications.

## Common order

| Rank | Kind |
|---:|---|
| 1 | Web browser |
| 2 | Email |
| 3 | PDF document |
| 4 | JPEG image |
| 5 | PNG image |
| 6 | HEIC image |
| 7 | GIF image |
| 8 | SVG image |
| 9 | WebP image |
| 10 | TIFF image |
| 11 | DNG raw photo |
| 12 | Plain text |
| 13 | Markdown |
| 14 | Rich text |
| 15 | Word document |
| 16 | Excel spreadsheet |
| 17 | PowerPoint presentation |
| 18 | Pages document |
| 19 | Numbers spreadsheet |
| 20 | Keynote presentation |
| 21 | CSV table |
| 22 | JSON data |
| 23 | XML document |
| 24 | YAML data |
| 25 | JavaScript source |
| 26 | TypeScript source |
| 27 | Python script |
| 28 | Shell script |
| 29 | PHP script |
| 30 | Swift source |
| 31 | C source |
| 32 | C++ source |
| 33 | CSS stylesheet |
| 34 | SQL source |
| 35 | ZIP archive |
| 36 | TAR archive |
| 37 | Gzip archive |
| 38 | 7-Zip archive |
| 39 | RAR archive |
| 40 | Mac disk image |
| 41 | MP3 audio |
| 42 | MPEG-4 audio |
| 43 | WAV audio |
| 44 | FLAC audio |
| 45 | AIFF audio |
| 46 | MPEG-4 video |
| 47 | QuickTime movie |
| 48 | Matroska video |
| 49 | AVI video |
| 50 | WebM video |
| 51 | EPUB ebook |
| 52 | Calendar event |
| 53 | Contact card |
| 54 | Phone call |
| 55 | Calendar subscription |
| 56 | Magnet link |
| 57 | Feed subscription |
| 58 | SSH link |
| 59 | FTP link |
| 60 | Text message |
