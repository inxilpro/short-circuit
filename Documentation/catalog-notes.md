# Catalog notes

Why `Short Circuit/Resources/Catalog.json` groups what it groups. **Read this before
editing the catalog**, and add to it when you change an entry: the point is that a future
reader can tell a deliberate grouping from an accident.

Every UTI in the catalog was seen as a real declaration in a Launch Services dump and
resolves through `UTType` to a declared type conforming to `public.item` or `public.data`.
No identifier here is guessed, and none is renamed to an invented `public.*` spelling.
That check establishes *eligibility* — it is not evidence that a handler write succeeds.

## What the catalog decides, and on what basis

- **Grouping.** Two UTIs are merged only when one explicitly declares conformance to the
  other, or their declarations otherwise show they are the same format. A shared
  extension or MIME tag is not enough; see the heuristic's failure modes in
  [launch-services.md](launch-services.md#what-the-shared-tag-heuristic-actually-produces).
- **Naming and category.** Human names over declaration strings.
- **The Common rank.** An editorial order, **not** telemetry and not inferred from how
  many apps are installed. Browser and mail lead, then everyday documents and images,
  text and office work, structured data and source code, archives and media, then
  specialized link roles. The ranks live in `Catalog.json`; they are bounded so Common
  stays a short list, which means useful formats are deliberately left unranked (standalone
  AAC, ISO images, fonts, legacy Office formats, templates, less common encodings). That
  is a size budget, not a claim they are unsupported.
- **Presence is per-Mac.** A catalog entry produces a Kind only if this Mac claims the
  content or registers the scheme. Entries that match nothing are dormant, which is why
  it is safe to add formats you have no app for.

[The design doc](design.md) supplies the Kind model and the coupled browser role. The
catalog names that Kind **"Web browser"**, keeps its stable `web-page` ID, and combines
HTML, XHTML, `http` and `https`; there is no second HTML Kind that could compete with it.
"Email" is the `mailto` role, and saved `.eml` messages stay separate.

Apple's [Uniform Type Identifiers documentation](https://developer.apple.com/documentation/uniformtypeidentifiers/)
and its [file and data type declaration guidance](https://developer.apple.com/documentation/uniformtypeidentifiers/defining-file-and-data-types-for-your-app)
provide the conformance background.

DNG is the ranked RAW representative; twenty-odd camera-specific RAW Kinds stay
searchable rather than being treated as aliases of each other.

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

Vendor-prefixed **primary** format identifiers are also intentional: PDF, Photoshop/PSB, Illustrator, EPS, GIF, BMP, PICT, Markdown, JavaScript, TypeScript, Java, AppleScript, legacy Office, iWork, QuickTime/M4V, RTFD, disk images/XIP, RAR, OpenEXR, and camera RAW formats often have a vendor namespace rather than a `public.*` identifier. Each was verified against a real declaration, and none is renamed to an invented `public.*` spelling.

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
| `public.markdown` | Deliberately absent. A hand test showed macOS refuses to assign it; the declaration has no supertypes, and the live type conforms to neither item nor data. Markdown uses `net.daringfireball.markdown`. |
| `com.microsoft.outlook15.icalendar` | Its `.ics` declaration identifies iCalendar and a calendar-event supertype, so it is a semantic alias, but its live type conforms to neither item nor data on this Mac. Do not rely on it as a catalog setter target; use `com.apple.ical.ics`. |
| `com.microsoft.outlook15.email-message` | Its `.eml` declaration identifies email-message content, but its live type also fails item/data conformance. Use `com.apple.mail.email`. |
| `com.araelium.querious.sqlite` | The declaration identifies SQLite, but the live type fails item/data conformance. Use `org.sqlite.sqlite`. |
| `org.matroska.mkv` and other guessed Matroska spellings | No MKV UTI or `.mkv` declaration was found in the captured inventory; no Apple system declaration was established. The Matroska entry intentionally has **empty `utis`**, extension `mkv`, and a Common rank. The loader may adopt a future claimed video-compatible `.mkv` type; the entry is dormant on this Mac. This is an extension-based catalog entry, not a fabricated UTI. |
| `com.microsoft.powerpoint.openxmlformats.presentationml.presentation` | Found as a claim without a corresponding declared format in the examined inventory. No explicit alias; use the verified organization-prefixed PPTX type. |
| `org.tukaani.xz-tar-archive` | Claimed spelling is not the verified declaration. The catalog uses the observed `org.tukaani.tar-xz-archive`. |
| `com.olympus.sr-raw-image`, `com.olympus.or-raw-image` | Additional `.orf` variants are not forced into the ordinary ORF entry: exact format equivalence was not established. Runtime adoption remains governed by the loader. |
| `public.tar-archive` versus `org.gnu.gnu-tar-archive` | Only the public TAR type is explicitly included. No forced assertion that every TAR dialect is the same format. |
| `public.cpio-archive` versus `cx.c3.pax-archive` | Neither is included. A shared `.pax` suffix is insufficient to assert an alias. |
| Apple Mail MBOX packages, Outlook MBOX, Outlook MSG/OLK types | Left to discovery. Folder layout, mailbox file layout, and proprietary Outlook messages must not be equated with EML or one another merely because they concern email. |
| Office BIFF generations, macro templates, iWork `*-tef`/templates, font collections, WOFF/WOFF2, standalone Opus identifiers | Outside this first catalog's size budget or insufficiently verified. No guessed UTI is added. Ogg audio retains the dump's `.opus` tag without asserting a standalone Opus UTI. |
| Broad base types and dynamic types | No `public.item`, `public.data`, generic image/audio/movie type, `com.apple.disk-image`, or `dyn.*` entry. The DMG entry uses concrete `com.apple.disk-image-udif`. |
| `zoommtg`, `vscode`, and other app-owned launch links | Not included. The catalog favors general roles with plausible competing handlers. FaceTime is the specifically requested exception; its two call schemes form an unranked call role. |

URL scheme roles: `mailto`, `tel`, `sms`, `facetime`/`facetime-audio`, `ftp`/`ftps`, `sftp`, `ssh`, `magnet`, `feed`/`rss`, and `webcal`/`webcals`, plus the browser pair. Grouped schemes describe a human role; FTP and SFTP remain separate. A scheme without registered claimants is dormant, not proof of an installed handler. `magnet`, `feed`, `rss` and `webcals` were not claimed by anything on the Mac this was authored against; that is not a reason to replace them with app-private schemes.

## Limits of these checks

`CatalogTests` checks the bundled file on every run: valid JSON and categories, unique
IDs, and no UTI or scheme owned by two entries. What it cannot check is whether a grouping
is *right* — that is what this document is for.

The original entries were validated by loading them against a captured dump with the
production `Catalog.decode` and `KindBuilder`, plus live read-only `UTType` lookups. That
confirmed declaration provenance, type eligibility, that no entry steals another's
explicit members, and that ordinary TIFF no longer absorbs Canon's TIFF RAW. No default
handler was changed and no setter was called, then or since.

Two standing caveats:

- Declarations differ between Macs. An identifier that conforms correctly here may not
  somewhere else, and vice versa.
- The loader's extension-adoption rule can still surface an identifier this file
  deliberately excludes. The excluded Markdown, Outlook and Querious types above are all
  `isSettable = false` when adopted that way, so they can appear but never be written.
  Omission from `utis` is therefore documented separately from runtime membership.
