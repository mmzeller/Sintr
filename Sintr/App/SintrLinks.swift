import Foundation

/// sintr:// links. Sectis puts them on the to-dos Sintr sends it, and in its menus:
///
///   sintr://note/<note ID>
///       Opens that note ("Open in Sintr" on a to-do).
///   sintr://new?title=…&place=project:<id>&placeTitle=…
///       Sectis's Record in Sintr: a new note with that title whose to-dos go to that project
///       or area (`place=area:<id>` for an area). Sintr asks before it starts recording.
///
/// Either can carry `sectis=<address>`, where your Sectis lives on the web, so the to-dos on a
/// note can open in Sectis.
@MainActor
enum SintrLinks {
    static func open(_ url: URL, store: NoteStore, appState: AppState) {
        guard url.scheme?.lowercased() == "sintr" else { return }
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).compactMap { item in
                item.value.map { (item.name.lowercased(), $0) }
            }, uniquingKeysWith: { first, _ in first })
        if let address = query["sectis"] { Sectis.learnAddress(address) }
        let action = url.host?.lowercased() ?? ""
        let path = url.pathComponents.filter { $0 != "/" }
        ActivityLog.add("Opened a sintr://\(action) link")

        switch action {
        case "note":
            guard let id = path.first.flatMap(UUID.init(uuidString:)) else {
                appState.linkMessage = "That link doesn't say which note to open."
                return
            }
            guard store.note(id) != nil else {
                appState.linkMessage = "That note isn't in Sintr on this \(Platform.deviceName). Notes don't sync between your devices, so it may be on your \(Platform.isMac ? "iPhone" : "Mac") — move it here with Export → Sintr backup."
                return
            }
            show(id, store: store, appState: appState)

        case "new":
            let title = (query["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let note = store.newNote(title: String(title.prefix(200)))
            if let place = place(query) {
                store.edit(note.id) { $0.sectisPlace = place }
            }
            show(note.id, store: store, appState: appState)
            appState.recordPrompt = note.id

        default:
            appState.linkMessage = "Sintr doesn't know what to do with that link."
        }
    }

    /// `place=project:<id>` or `place=area:<id>`, titled by `placeTitle`.
    static func place(_ query: [String: String]) -> SectisFormat.Place? {
        guard let value = query["place"], let colon = value.firstIndex(of: ":") else { return nil }
        let kind = String(value[..<colon]).lowercased()
        let id = String(value[value.index(after: colon)...])
        guard !id.isEmpty, id.count <= 80, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        let title = (query["placetitle"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case "project": return SectisFormat.Place(kind: .project, id: id, title: title.isEmpty ? "Sectis project" : title)
        case "area": return SectisFormat.Place(kind: .area, id: id, title: title.isEmpty ? "Sectis area" : title)
        default: return nil
        }
    }

    /// Opens a note, showing all notes if the list is filtered to a folder it isn't in.
    private static func show(_ id: UUID, store: NoteStore, appState: AppState) {
        let folder = store.note(id)?.folderID
        switch appState.folderFilter {
        case .all: break
        case .unfiled: if folder != nil { appState.folderFilter = .all }
        case .folder(let shown): if folder != shown { appState.folderFilter = .all }
        }
        appState.selection = id
    }
}
