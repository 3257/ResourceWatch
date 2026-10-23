import Testing
@testable import ResourceWatch

@Test @MainActor func gateHoldsChangesWhileAMenuIsOpenAndReleasesThemInOrder() {
    let gate = MenuUpdateGate()
    var applied: [Int] = []
    gate.submit { applied.append(1) }
    #expect(applied == [1])
    gate.setHolding(true)
    gate.submit { applied.append(2) }
    gate.submit { applied.append(3) }
    #expect(applied == [1])
    gate.setHolding(false)
    #expect(applied == [1, 2, 3])
    gate.setHolding(false)
    #expect(applied == [1, 2, 3])
}

@Test @MainActor func releasedChangesMaySubmitMoreChanges() {
    let gate = MenuUpdateGate()
    var applied: [String] = []
    gate.setHolding(true)
    gate.submit { applied.append("sample"); gate.submit { applied.append("follow-up") } }
    gate.setHolding(false)
    #expect(applied == ["sample", "follow-up"])
}
