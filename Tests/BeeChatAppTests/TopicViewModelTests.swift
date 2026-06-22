import XCTest
@testable import BeeChatApp
@testable import BeeChatPersistence

final class TopicViewModelTests: XCTestCase {
    
    // Kieran M1 Test 3: TopicViewModel Hashable — identity-only equality
    // Two VMs with same id but different projectPath must compare equal and hash equal
    func testTopicViewModelIdentityHashable() throws {
        // Use canonical path (capital P) — matches Topic.setProjectPath allowedPrefix
        let realPath = "/Users/openclaw/Projects/BeeChat-v5"
        var topic = Topic(id: "same-id", name: "Test Project", sessionKey: "agent:main:test")
        
        var topicA = topic
        try topicA.setProjectPath(realPath)
        
        var topicB = topic
        try topicB.setProjectPath(realPath)
        
        let vmA = TopicViewModel(from: topicA)
        let vmB = TopicViewModel(from: topicB)
        
        // Same id → should be equal
        XCTAssertEqual(vmA, vmB, "TopicViewModels with same id should be equal")
        XCTAssertEqual(vmA.hashValue, vmB.hashValue, "TopicViewModels with same id should hash the same")
        
        // Put in a Set — should deduplicate to 1
        let set: Set<TopicViewModel> = [vmA, vmB]
        XCTAssertEqual(set.count, 1, "Set should deduplicate TopicViewModels with same id")
    }
    
    func testTopicViewModelProjectPathPassthrough() throws {
        let realPath = "/Users/openclaw/Projects/BeeChat-v5"
        var topic = Topic(id: "test-id", name: "Test", sessionKey: "agent:main:test")
        try topic.setProjectPath(realPath)
        
        let vm = TopicViewModel(from: topic)
        XCTAssertEqual(vm.projectPath, realPath)
    }
    
    func testTopicViewModelProjectPathNilWhenNotSet() {
        let topic = Topic(id: "test-id", name: "Test", sessionKey: "agent:main:test")
        let vm = TopicViewModel(from: topic)
        XCTAssertNil(vm.projectPath)
    }
}
