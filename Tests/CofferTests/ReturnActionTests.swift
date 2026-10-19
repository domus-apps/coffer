import Testing

@testable import Coffer

@Test func returnCopiesAndCommandReturnPastesByDefault() {
    #expect(ReturnAction.forReturn(commandHeld: false, pastesWithReturn: false) == .copy)
    #expect(ReturnAction.forReturn(commandHeld: true, pastesWithReturn: false) == .paste)
}

@Test func pasteWithReturnFlipsBothKeys() {
    #expect(ReturnAction.forReturn(commandHeld: false, pastesWithReturn: true) == .paste)
    #expect(ReturnAction.forReturn(commandHeld: true, pastesWithReturn: true) == .copy)
}
