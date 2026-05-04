//  Tests del comparator de orden + invariante carpetas-arriba en los
//  6 modos de FilesSortMode.

@testable import NodeClientCore
import XCTest

@MainActor
final class FilesViewModelSortTests: XCTestCase {
    // MARK: - Invariante carpetas siempre arriba

    func test_folders_alwaysAboveFiles_inAllModes() async {
        for mode in FilesSortMode.allCases {
            let viewModel = await makeViewModel(items: [
                makeFile(id: "a", name: "alpha.txt", size: 100, updated: dateA),
                makeFolder(id: "b", name: "zeta-folder"),
                makeFile(id: "c", name: "beta.txt", size: 200, updated: dateB),
                makeFolder(id: "d", name: "alpha-folder")
            ])
            viewModel.updateSortMode(mode)

            let visible = viewModel.filesForFolder("/")
            XCTAssertEqual(visible.count, 4, "mode=\(mode)")
            XCTAssertTrue(visible[0].isFolder, "mode=\(mode): pos 0 should be folder")
            XCTAssertTrue(visible[1].isFolder, "mode=\(mode): pos 1 should be folder")
            XCTAssertFalse(visible[2].isFolder, "mode=\(mode): pos 2 should be file")
            XCTAssertFalse(visible[3].isFolder, "mode=\(mode): pos 3 should be file")
        }
    }

    // MARK: - Nombre

    func test_nameAscending_sortsAZWithinGroup() async {
        let viewModel = await makeViewModel(items: [
            makeFile(id: "a", name: "zeta.txt"),
            makeFile(id: "b", name: "alpha.txt"),
            makeFile(id: "c", name: "mu.txt")
        ])
        viewModel.updateSortMode(.nameAscending)

        let visible = viewModel.filesForFolder("/")
        XCTAssertEqual(visible.map(\.name), ["alpha.txt", "mu.txt", "zeta.txt"])
    }

    func test_nameDescending_sortsZAWithinGroup() async {
        let viewModel = await makeViewModel(items: [
            makeFile(id: "a", name: "zeta.txt"),
            makeFile(id: "b", name: "alpha.txt"),
            makeFile(id: "c", name: "mu.txt")
        ])
        viewModel.updateSortMode(.nameDescending)

        let visible = viewModel.filesForFolder("/")
        XCTAssertEqual(visible.map(\.name), ["zeta.txt", "mu.txt", "alpha.txt"])
    }

    // MARK: - Fecha de modificación

    func test_dateModifiedDescending_mostRecentFirst() async {
        let viewModel = await makeViewModel(items: [
            makeFile(id: "a", name: "old.txt", updated: dateA),
            makeFile(id: "b", name: "new.txt", updated: dateC),
            makeFile(id: "c", name: "mid.txt", updated: dateB)
        ])
        viewModel.updateSortMode(.dateModifiedDescending)

        let visible = viewModel.filesForFolder("/")
        XCTAssertEqual(visible.map(\.name), ["new.txt", "mid.txt", "old.txt"])
    }

    func test_dateModifiedAscending_oldestFirst() async {
        let viewModel = await makeViewModel(items: [
            makeFile(id: "a", name: "old.txt", updated: dateA),
            makeFile(id: "b", name: "new.txt", updated: dateC),
            makeFile(id: "c", name: "mid.txt", updated: dateB)
        ])
        viewModel.updateSortMode(.dateModifiedAscending)

        let visible = viewModel.filesForFolder("/")
        XCTAssertEqual(visible.map(\.name), ["old.txt", "mid.txt", "new.txt"])
    }

    func test_dateModified_nilDates_fallToBackOfList() async {
        let viewModel = await makeViewModel(items: [
            makeFile(id: "a", name: "withDate.txt", updated: dateA),
            makeFile(id: "b", name: "noDate.txt", updated: nil)
        ])
        viewModel.updateSortMode(.dateModifiedDescending)

        let visible = viewModel.filesForFolder("/")
        XCTAssertEqual(visible.map(\.name), ["withDate.txt", "noDate.txt"])
    }

    // MARK: - Tamaño

    func test_sizeDescending_largestFirst() async {
        let viewModel = await makeViewModel(items: [
            makeFile(id: "a", name: "small.txt", size: 100),
            makeFile(id: "b", name: "large.txt", size: 1_000),
            makeFile(id: "c", name: "mid.txt", size: 500)
        ])
        viewModel.updateSortMode(.sizeDescending)

        let visible = viewModel.filesForFolder("/")
        XCTAssertEqual(visible.map(\.name), ["large.txt", "mid.txt", "small.txt"])
    }

    func test_sizeAscending_smallestFirst() async {
        let viewModel = await makeViewModel(items: [
            makeFile(id: "a", name: "small.txt", size: 100),
            makeFile(id: "b", name: "large.txt", size: 1_000),
            makeFile(id: "c", name: "mid.txt", size: 500)
        ])
        viewModel.updateSortMode(.sizeAscending)

        let visible = viewModel.filesForFolder("/")
        XCTAssertEqual(visible.map(\.name), ["small.txt", "mid.txt", "large.txt"])
    }

    func test_size_equalSize_tiesBreakByName() async {
        let viewModel = await makeViewModel(items: [
            makeFile(id: "a", name: "zeta.txt", size: 100),
            makeFile(id: "b", name: "alpha.txt", size: 100)
        ])
        viewModel.updateSortMode(.sizeDescending)

        let visible = viewModel.filesForFolder("/")
        XCTAssertEqual(visible.map(\.name), ["alpha.txt", "zeta.txt"])
    }

    // MARK: - Sort group

    func test_sortMode_groupClassification() {
        XCTAssertEqual(FilesSortMode.nameAscending.group, .name)
        XCTAssertEqual(FilesSortMode.nameDescending.group, .name)
        XCTAssertEqual(FilesSortMode.dateModifiedAscending.group, .date)
        XCTAssertEqual(FilesSortMode.dateModifiedDescending.group, .date)
        XCTAssertEqual(FilesSortMode.sizeAscending.group, .size)
        XCTAssertEqual(FilesSortMode.sizeDescending.group, .size)
    }

    // MARK: - Helpers

    private let dateA = Date(timeIntervalSince1970: 1_700_000_000)
    private let dateB = Date(timeIntervalSince1970: 1_700_500_000)
    private let dateC = Date(timeIntervalSince1970: 1_701_000_000)

    private func makeFile(
        id: String,
        name: String,
        size: Int64 = 0,
        updated: Date? = nil
    ) -> FileItem {
        FileItem(
            id: id,
            name: name,
            path: "/\(name)",
            detail: "",
            systemImage: "doc",
            isFolder: false,
            isShared: false,
            isOffline: false,
            sizeBytes: size,
            updatedAt: updated
        )
    }

    private func makeFolder(id: String, name: String) -> FileItem {
        FileItem(
            id: id,
            name: name,
            path: "/\(name)",
            detail: "",
            systemImage: "folder",
            isFolder: true,
            isShared: false,
            isOffline: false
        )
    }

    private func makeViewModel(items: [FileItem]) async -> FilesViewModel {
        let vm = FilesViewModel(
            apiClient: FailingMockAPIClient(),
            sessionTokenProvider: { "tok" },
            syncStateStore: SortInMemorySyncStore(),
            syncNamespaceProvider: { "test" },
            filesRepository: SortStubRepository(items: items)
        )
        await vm.loadFiles()
        return vm
    }
}

// MARK: - Doubles

private final class SortStubRepository: FilesRepositoryProtocol {
    let items: [FileItem]
    init(items: [FileItem]) { self.items = items }

    func synchronizeFiles(token: String, namespace: String) async throws -> [FileItem] {
        items
    }

    func readCachedFiles(namespace: String) -> [FileItem] {
        []
    }
}

private final class SortInMemorySyncStore: FilesSyncStateStore {
    func readSnapshot(namespace: String) -> FilesSyncSnapshot? { nil }
    func writeSnapshot(_ snapshot: FilesSyncSnapshot, namespace: String) {}
    func clearSnapshot(namespace: String) {}
}

private final class FailingMockAPIClient: NodeAPIClientProtocol {
    func login(username: String, password: String) async throws -> AuthLoginResponse {
        throw NodeAPIError.transport("not used")
    }
    func register(invitationCode: String, username: String, password: String) async throws -> AuthRegisterResponse {
        throw NodeAPIError.transport("not used")
    }
    func refresh(token: String) async throws -> AuthLoginResponse {
        throw NodeAPIError.transport("not used")
    }
    func fetchProfile(token: String) async throws -> AuthProfileResponse {
        throw NodeAPIError.transport("not used")
    }
    func fetchTree(token: String, sinceCursor: Int64?) async throws -> FsTreeResponse {
        throw NodeAPIError.transport("not used")
    }
    func downloadFileContent(token: String, entryId: String, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        throw NodeAPIError.transport("not used")
    }
    func upsertEntry(token: String, request: FsUpsertEntryRequest) async throws -> FsEntryResponse {
        throw NodeAPIError.transport("not used")
    }
    func patchEntry(token: String, entryId: String, request: FsPatchEntryRequest) async throws -> FsEntryResponse {
        throw NodeAPIError.transport("not used")
    }
    func deleteEntry(token: String, entryId: String) async throws {
        throw NodeAPIError.transport("not used")
    }
    func createUploadSession(token: String, request: FileUploadSessionCreateRequest) async throws -> FileUploadSessionResponse {
        throw NodeAPIError.transport("not used")
    }
    func appendUploadChunk(token: String, sessionId: String, offset: Int64, chunk: Data) async throws -> FileUploadSessionResponse {
        throw NodeAPIError.transport("not used")
    }
    func completeUploadSession(token: String, sessionId: String) async throws -> FileContentUploadResponse {
        throw NodeAPIError.transport("not used")
    }
    func logout(token: String) async throws {
        throw NodeAPIError.transport("not used")
    }
}
