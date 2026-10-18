import XCTest
@testable import RelayCore

final class AlbumNavigationTests: XCTestCase {
    private let albumID = UUID(uuidString: "FBA5930D-F668-4DCA-89A9-24DF38BDB289")!

    func testEveryDestinationRoundTripsWithoutLosingItsKindOrIdentifier() {
        let destinations: [AlbumDestination] = [
            .library(.sent), .library(.received),
            .sent(albumID), .received(albumID), .importing(albumID)
        ]
        for destination in destinations {
            XCTAssertEqual(AlbumDestination(url: destination.url), destination)
        }
        XCTAssertEqual(Set(destinations).count, destinations.count)
    }

    func testLibraryRootDefaultsToSentAndExplicitSectionsRemainDistinct() {
        for value in ["dropack://albums", "dropack://albums/", "DROPACK://ALBUMS"] {
            XCTAssertEqual(AlbumDestination(url: URL(string: value)!), .library(.sent), value)
        }
        XCTAssertEqual(AlbumDestination(url: URL(string: "dropack://albums/received")!), .library(.received))
        XCTAssertEqual(AlbumDestination.library(.sent).url.absoluteString, "dropack://albums/sent")
    }

    func testAlbumRoutesUseOnlyStableAlbumIdentity() {
        // Snapshots are intentionally absent from the public route contract.
        // Both sides can resolve the album's latest local snapshot independently.
        let sent = AlbumDestination.sent(albumID)
        let received = AlbumDestination.received(albumID)
        XCTAssertEqual(sent.url.absoluteString, "dropack://albums/sent/fba5930d-f668-4dca-89a9-24df38bdb289")
        XCTAssertEqual(received.url.absoluteString, "dropack://albums/received/fba5930d-f668-4dca-89a9-24df38bdb289")
        XCTAssertNotEqual(sent, received)
    }

    func testStandaloneImportUsesItsOwnJobNamespace() {
        let destination = AlbumDestination.importing(albumID)
        XCTAssertEqual(destination.url.absoluteString, "dropack://imports/fba5930d-f668-4dca-89a9-24df38bdb289")
        XCTAssertNotEqual(destination, .received(albumID))
    }

    func testRejectsForeignUrlsMalformedPathsAndActionParameters() {
        let id = albumID.uuidString
        let rejected = [
            "file:///tmp/album.dropack", "https://albums/sent/\(id)",
            "dropack://other/sent/\(id)", "dropack:///albums/sent/\(id)",
            "dropack://albums/shared/\(id)", "dropack://albums/sent/not-a-uuid",
            "dropack://albums/sent/", "dropack://albums//sent/\(id)",
            "dropack://albums/sent/\(id)/extra", "dropack://albums/sent/\(id)/",
            "dropack://albums/sent/\(id)?start=true", "dropack://albums/sent/\(id)#delete",
            "dropack://albums?", "dropack://albums#",
            "dropack://user@albums/sent/\(id)", "dropack://user:password@albums/sent/\(id)",
            "dropack://albums:80/sent/\(id)", "dropack://albums/sent%2F\(id)",
            "dropack://albums/%73ent/\(id)", "dropack://albums/sent/../received/\(id)",
            "dropack://imports", "dropack://imports/", "dropack://imports/not-a-uuid",
            "dropack://imports/\(id)/extra", "dropack://imports/\(id)?resume=true"
        ]
        for value in rejected {
            XCTAssertNil(AlbumDestination(url: URL(string: value)!), value)
        }
    }

    func testLegacyActivityLinksRemainOwnedByTheExistingParser() {
        for kind in [ActivityTaskDestination.Kind.packaging, .importing] {
            let url = URL(string: "dropack://activity/\(kind.rawValue)/\(albumID.uuidString)")!
            XCTAssertNil(AlbumDestination(url: url))
            XCTAssertEqual(ActivityTaskDestination(url: url)?.jobID, albumID)
            XCTAssertEqual(ActivityTaskDestination(url: url)?.kind, kind)
        }
    }

    func testRepeatedLinksProduceDistinctNavigationRequests() {
        let first = AlbumNavigationRequest(destination: .received(albumID))
        let second = AlbumNavigationRequest(destination: .received(albumID))
        XCTAssertEqual(first.destination, second.destination)
        XCTAssertNotEqual(first.id, second.id)
    }
}
