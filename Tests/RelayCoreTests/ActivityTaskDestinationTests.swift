import XCTest
@testable import RelayCore

final class ActivityTaskDestinationTests: XCTestCase {
    func testRoutesToTheExactPackageOrImportWithoutStartingWork() {
        let id = UUID()
        for kind in [ActivityTaskDestination.Kind.packaging, .importing] {
            let route = ActivityTaskDestination(url: URL(string: "dropack://activity/\(kind.rawValue)/\(id.uuidString)")!)
            XCTAssertEqual(route?.jobID, id)
            XCTAssertEqual(route?.kind, kind)
        }
    }

    func testRejectsFilesForeignHostsAndExtraInstructions() {
        let id = UUID().uuidString
        let rejected = [
            "file:///tmp/package.dropack", "https://activity/packaging/\(id)",
            "dropack://other/packaging/\(id)", "dropack://activity/delete/\(id)",
            "dropack://activity/packaging/not-a-uuid", "dropack://activity/packaging/\(id)/extra",
            "dropack://activity/packaging/\(id)?start=true", "dropack://activity/packaging/\(id)#delete",
            "dropack://user@activity/packaging/\(id)", "dropack://activity:80/packaging/\(id)"
        ]
        for value in rejected {
            XCTAssertNil(ActivityTaskDestination(url: URL(string: value)!), value)
        }
    }
}
