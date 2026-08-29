import Foundation

/* One history entry: what was copied. Images keep their PNG-normalized
   data so a re-copy is byte-faithful and identical copies dedup; file
   copies keep the URLs so a re-copy pastes the files themselves, not a
   rendering of them. Previews and thumbnails are derived in the UI layer,
   never stored here. */
enum ClipboardItem: Equatable, Codable {
    case text(String)
    case image(Data)
    case files([URL])
}
