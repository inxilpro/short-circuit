import Foundation
import Testing
@testable import Short_Circuit

struct SettableMemberTests {
    @Test func liveRuleFollowsItemOrDataConformance() {
        #expect(KindBuilder.isSettableLive("public.plain-text"))
        #expect(KindBuilder.isSettableLive("public.folder"), "public.item conformance is enough")
        #expect(!KindBuilder.isSettableLive("com.example.never-declared-anywhere"))
    }

    @Test func unsettableMembersDoNotSplitAKind() throws {
        var builder = Fixture.offlineBuilder
        builder.isSettableType = { $0 != "public.markdown" }
        let markdown = try #require(builder.build(from: try Fixture.snapshot("markdown.lsdump")).first { $0.utis.contains("public.markdown") })

        #expect(markdown.members.first { $0.target == .uti("public.markdown") }?.isSettable == false)
        #expect(markdown.members.first { $0.target == .uti("net.daringfireball.markdown") }?.isSettable == true)
        #expect(!markdown.isSplit, "Only net.daringfireball.markdown has a handler that can change")
        #expect(markdown.defaultApp?.bundleID == "com.sublimetext.4")
    }

    @Test func kindsWithNoSettableMemberAreDropped() throws {
        var builder = Fixture.offlineBuilder
        builder.isSettableType = { !["public.markdown", "net.daringfireball.markdown"].contains($0) }
        let output = builder.analyze(try Fixture.snapshot("markdown.lsdump"))
        #expect(!output.kinds.contains { $0.utis.contains("public.markdown") })
        #expect(output.droppedUnsettableKindCount == 1)
        #expect(output.unsettableUTIs == ["public.markdown", "net.daringfireball.markdown"])
        #expect(output.kinds.contains { $0.utis.contains("public.plain-text") })
    }

    @Test func schemesStaySettable() throws {
        var builder = Fixture.offlineBuilder
        builder.isSettableType = { _ in false }
        let kinds = builder.build(from: try Fixture.snapshot("schemes.lsdump"))
        #expect(kinds.contains { $0.id == KindBuilder.emailID })
        let web = try #require(kinds.first { $0.id == KindBuilder.webPageID })
        #expect(web.members.allSatisfy { member in
            if case .scheme = member.target { member.isSettable } else { !member.isSettable }
        })
    }
}
