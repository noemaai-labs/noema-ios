import Testing

@_silgen_name("noema_llama_server_penalty_clone_consistent_for_test")
private func noema_llama_server_penalty_clone_consistent_for_test() -> Int32

@Test func penaltySamplerClonePreservesCountsAcrossRollover() {
    #expect(noema_llama_server_penalty_clone_consistent_for_test() == 1)
}
