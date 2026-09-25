import Foundation
import Testing
@testable import Ballast

@Suite struct TreemapTests {
    @Test func tilesFillTheRectExactly() {
        let values: [Double] = [500, 300, 120, 50, 20, 7, 3]
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 400)
        let rects = TreemapLayout.layout(values, in: bounds)

        #expect(rects.count == values.count)
        let area = rects.reduce(0) { $0 + $1.width * $1.height }
        #expect(abs(area - bounds.width * bounds.height) < 1)
        for rect in rects {
            #expect(bounds.insetBy(dx: -0.01, dy: -0.01).contains(rect))
        }
        // Proportional: the biggest value gets the biggest tile.
        #expect(rects[0].width * rects[0].height > rects[1].width * rects[1].height)
    }

    @Test func emptyInputIsHarmless() {
        #expect(TreemapLayout.layout([], in: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
        #expect(TreemapLayout.layout([1, 2], in: .zero) == [.zero, .zero])
    }
}

@Suite struct WalkerTests {
    @Test func measuresASmallTreeLikeDu() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ballast-walk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: "a/b"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "c"), withIntermediateDirectories: true)
        try Data(count: 100_000).write(to: root.appending(path: "a/one.bin"))
        try Data(count: 50_000).write(to: root.appending(path: "a/b/two.bin"))
        try Data(count: 10_000).write(to: root.appending(path: "c/three.bin"))
        // A hard link must be counted once.
        try fm.linkItem(at: root.appending(path: "a/one.bin"), to: root.appending(path: "c/link.bin"))

        var nodes: [WalkNode] = []
        try Walker.walk(root.path) { nodes.append($0) }

        let top = try #require(nodes.last)
        #expect(top.local == 0)
        #expect(nodes.count == 4)            // root, a, a/b, c
        #expect(top.files == 3)              // the link is skipped
        #expect(top.total >= 160_000)        // allocated size is at least the logical size
        #expect(top.total < 400_000)
        // Children are emitted before parents.
        #expect(nodes.firstIndex { $0.name == "b" }! < nodes.firstIndex { $0.name == "a" }!)
    }
}

@Suite struct CleanerTests {
    @Test func structuralGuard() {
        let home = NSHomeDirectory()
        #expect(!Cleaner.canRemove(home))
        #expect(!Cleaner.canRemove(home + "/Documents"))
        #expect(!Cleaner.canRemove(home + "/Library/Caches"))
        #expect(!Cleaner.canRemove("/usr/local/lib"))
        #expect(Cleaner.canRemove(home + "/projects/app/node_modules"))
        #expect(Cleaner.canRemove(home + "/Library/Caches/com.example.app"))
    }
}
