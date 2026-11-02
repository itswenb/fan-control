import Foundation
import Testing
import FanCore

struct LeaseHeartbeatInboxTests {
    @Test func arrivalTimesStaySeparateMonotonicAndCloseWithConnection() {
        let inbox = LeaseHeartbeatInbox()
        inbox.record(.fan, at: 12)
        inbox.record(.fan, at: 10)
        inbox.record(.sleep, at: 15)
        #expect(inbox.latest(.fan) == 12 && inbox.latest(.sleep) == 15)
        inbox.close()
        inbox.record(.fan, at: 20)
        #expect(!inbox.isOpen && inbox.latest(.fan) == nil && inbox.latest(.sleep) == nil)
    }

    @Test func fanHeartbeatCanReadRecentCompletedStatusButNotStaleOrClosedStatus() throws {
        let inbox = LeaseHeartbeatInbox(), owner = UUID()
        var reply = HelperReply(available: true, status: SessionStatus(owner: owner, policies: [], pendingRecovery: [], message: nil))
        reply.ownsSession = true
        inbox.publishFanReply(reply, at: 10)
        inbox.record(.fan, at: 16)
        #expect(try #require(inbox.recentFanReply(at: 16)).status?.owner == owner)
        #expect(inbox.latest(.fan) == 16)
        #expect(inbox.recentFanReply(at: 25) != nil)
        #expect(inbox.recentFanReply(at: 25.01) == nil)
        inbox.invalidateFanReply()
        #expect(inbox.recentFanReply(at: 11) == nil)
        inbox.publishFanReply(reply, at: 30)
        inbox.close()
        inbox.publishFanReply(reply, at: 31)
        #expect(inbox.recentFanReply(at: 31) == nil)
    }

    @Test func sleepHeartbeatCacheExpiresAndCannotSurviveConnectionClose() {
        let inbox = LeaseHeartbeatInbox(), client = UUID()
        var reply = HelperReply(available: false)
        reply.sleepStatus = SleepInhibitionStatus(available: true, owner: client, active: true)
        reply.ownsSession = true
        inbox.publishSleepReply(reply, at: 10)
        #expect(inbox.recentSleepReply(at: 16)?.sleepStatus?.owner == client)
        #expect(inbox.recentSleepReply(at: 25.01) == nil)
        inbox.invalidateSleepReply()
        #expect(inbox.recentSleepReply(at: 16) == nil)
        inbox.publishSleepReply(reply, at: 20)
        inbox.close()
        #expect(inbox.recentSleepReply(at: 20) == nil)
    }
}
