import XCTest
@testable import UITestBenchCore

/// 标注的撤销/重做。规则只有一条：新画一笔会丢弃所有可重做的步骤——
/// 这也是所有绘图软件的共同预期。
final class AnnotationDocumentTests: XCTestCase {
    private func rectangle(x: CGFloat) -> Annotation {
        Annotation(shape: .rectangle(CGRect(x: x, y: 10, width: 20, height: 20)))
    }

    func testAddingAnnotationEnablesUndo() {
        var document = AnnotationDocument()

        document.add(rectangle(x: 10))

        XCTAssertEqual(document.annotations.count, 1)
        XCTAssertTrue(document.canUndo)
        XCTAssertFalse(document.canRedo)
    }

    func testUndoThenRedoRestoresTheSameAnnotation() {
        var document = AnnotationDocument()
        let first = rectangle(x: 10)
        let second = rectangle(x: 40)
        document.add(first)
        document.add(second)

        document.undo()
        XCTAssertEqual(document.annotations, [first])
        XCTAssertTrue(document.canRedo)

        document.redo()
        XCTAssertEqual(document.annotations, [first, second])
        XCTAssertFalse(document.canRedo)
    }

    func testNewAnnotationAfterUndoDiscardsRedoStack() {
        var document = AnnotationDocument()
        document.add(rectangle(x: 10))
        document.undo()

        document.add(rectangle(x: 60))

        XCTAssertFalse(document.canRedo)
        XCTAssertEqual(document.annotations.count, 1)
    }

    func testUndoAndRedoOnEmptyDocumentDoNothing() {
        var document = AnnotationDocument()

        document.undo()
        document.redo()

        XCTAssertEqual(document.annotations, [])
        XCTAssertFalse(document.canUndo)
        XCTAssertFalse(document.canRedo)
    }

    func testRemoveAllResetsBothStacks() {
        var document = AnnotationDocument()
        document.add(rectangle(x: 10))
        document.add(rectangle(x: 30))
        document.undo()

        document.removeAll()

        XCTAssertEqual(document.annotations, [])
        XCTAssertFalse(document.canUndo)
        XCTAssertFalse(document.canRedo)
    }
}
