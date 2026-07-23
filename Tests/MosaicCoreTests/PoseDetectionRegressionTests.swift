import CoreGraphics
import Testing
@testable import MosaicCore

@Test func scaledMaskBoundsUseSourceImageCoordinates() throws {
    let width = 12
    let height = 8
    var pixels = [UInt8](repeating: 0, count: width * height)
    for y in 2...6 {
        for x in 3...9 {
            pixels[y * width + x] = 255
        }
    }

    let bounds = try #require(VisionPersonDetector.normalizedBounds(
        in: pixels,
        width: width,
        height: height
    ))

    #expect(abs(bounds.x - 3.0 / 12.0) < 0.0001)
    #expect(abs(bounds.y - 2.0 / 8.0) < 0.0001)
    #expect(abs(bounds.width - 7.0 / 12.0) < 0.0001)
    #expect(abs(bounds.height - 5.0 / 8.0) < 0.0001)
}

@Test func personDetectionMergeKeepsMasksAndAddsUnmatchedRectangles() {
    let instancePersons = (0..<4).map { index in
        PersonDetection(bounds: NormalizedRect(
            x: Double(index) * 0.20,
            y: 0.1,
            width: 0.15,
            height: 0.7
        ))
    }
    var rectangles = instancePersons.map { person in
        PersonDetection(bounds: person.bounds)
    }
    let enclosingDuplicate = PersonDetection(bounds: NormalizedRect(x: 0, y: 0.05, width: 0.22, height: 0.8))
    let fifth = PersonDetection(bounds: NormalizedRect(x: 0.84, y: 0.2, width: 0.12, height: 0.6))
    rectangles.append(enclosingDuplicate)
    rectangles.append(fifth)

    let merged = VisionPersonDetector.mergePersonDetections(
        instancePersons: instancePersons,
        rectanglePersons: rectangles
    )

    #expect(merged.count == 5)
    #expect(merged[0].bounds == instancePersons[0].bounds)
    #expect(merged.contains { $0.bounds == fifth.bounds })
    #expect(!merged.contains { $0.bounds == enclosingDuplicate.bounds })
}

@Test func actualCropRegionUsesIntegralPixelRect() {
    let imageSize = CGSize(width: 1919, height: 1079)
    let requested = NormalizedRect(x: 0.1234, y: 0.2345, width: 0.2711, height: 0.3197)
    let cropRect = requested.cgRect(imageSize: imageSize, origin: .topLeft)

    let actual = PoseDetectionMath.actualRegion(for: cropRect, imageSize: imageSize)

    #expect(abs(actual.x * imageSize.width - cropRect.minX) < 0.0001)
    #expect(abs(actual.y * imageSize.height - cropRect.minY) < 0.0001)
    #expect(abs(actual.width * imageSize.width - cropRect.width) < 0.0001)
    #expect(abs(actual.height * imageSize.height - cropRect.height) < 0.0001)
}

@Test func rotatedPoseCoordinatesRestoreToOriginalCrop() {
    let region = NormalizedRect(x: 0.2, y: 0.3, width: 0.5, height: 0.25)
    let clockwiseJoint = PoseJoint(name: .nose, x: 0.7, y: 0.25, confidence: 0.9)
    let counterClockwiseJoint = PoseJoint(name: .nose, x: 0.3, y: 0.75, confidence: 0.9)

    let fromClockwise = PoseDetectionMath.restoreJoints(
        [clockwiseJoint],
        from: region,
        rotation: .clockwise
    )[0]
    let fromCounterClockwise = PoseDetectionMath.restoreJoints(
        [counterClockwiseJoint],
        from: region,
        rotation: .counterClockwise
    )[0]

    #expect(abs(fromClockwise.x - 0.325) < 0.0001)
    #expect(abs(fromClockwise.y - 0.375) < 0.0001)
    #expect(abs(fromCounterClockwise.x - 0.325) < 0.0001)
    #expect(abs(fromCounterClockwise.y - 0.375) < 0.0001)
}

@Test func poseCandidateScorePrefersTargetPerson() {
    let person = NormalizedRect(x: 0.2, y: 0.1, width: 0.35, height: 0.8)
    let target = makePoseJoints(centerX: 0.375, centerY: 0.5, confidence: 0.9)
    let neighbor = makePoseJoints(centerX: 0.78, centerY: 0.5, confidence: 0.98)

    let targetScore = PoseDetectionMath.evaluate(
        joints: target,
        personBounds: person,
        maskNearMatches: [Bool](repeating: true, count: target.count)
    )
    let neighborScore = PoseDetectionMath.evaluate(
        joints: neighbor,
        personBounds: person,
        maskNearMatches: [Bool](repeating: false, count: neighbor.count)
    )

    #expect(targetScore.score > neighborScore.score)
    #expect(targetScore.rectangleInsideRatio == 1)
    #expect(targetScore.maskNearRatio == 1)
    #expect(neighborScore.maskNearRatio == 0)
}

@Test func poseAssociationRejectsMostlyForeignJoints() {
    let mixed = PoseCandidateEvaluation(
        score: 0.8,
        centerScore: 0.9,
        rectangleInsideRatio: 0.7,
        maskNearRatio: 0.3,
        meanConfidence: 0.9,
        jointCompleteness: 1
    )
    let associated = PoseCandidateEvaluation(
        score: 0.8,
        centerScore: 0.9,
        rectangleInsideRatio: 0.7,
        maskNearRatio: 0.7,
        meanConfidence: 0.9,
        jointCompleteness: 1
    )

    #expect(!PoseDetectionMath.isAssociatedWithPerson(mixed, hasMask: true))
    #expect(PoseDetectionMath.isAssociatedWithPerson(associated, hasMask: true))
}

@Test func duplicatePoseIdentificationUsesNamedJointDistance() {
    let firstBounds = NormalizedRect(x: 0.1, y: 0.1, width: 0.4, height: 0.8)
    let secondBounds = NormalizedRect(x: 0.12, y: 0.1, width: 0.4, height: 0.8)
    let first = makePoseJoints(centerX: 0.3, centerY: 0.5, confidence: 0.9)
    let samePerson = first.map {
        PoseJoint(name: $0.name, x: $0.x + 0.004, y: $0.y - 0.003, confidence: $0.confidence)
    }
    let otherPerson = makePoseJoints(centerX: 0.75, centerY: 0.5, confidence: 0.9)

    #expect(PoseDetectionMath.areDuplicatePoses(
        first,
        lhsBounds: firstBounds,
        samePerson,
        rhsBounds: secondBounds
    ))
    #expect(!PoseDetectionMath.areDuplicatePoses(
        first,
        lhsBounds: firstBounds,
        otherPerson,
        rhsBounds: NormalizedRect(x: 0.6, y: 0.1, width: 0.3, height: 0.8)
    ))
}

@Test func horizontalPersonEnablesRotationsAndLongAxisRegions() {
    let person = NormalizedRect(x: 0.1, y: 0.35, width: 0.8, height: 0.25)
    let face = NormalizedRect(x: 0.12, y: 0.42, width: 0.08, height: 0.1)

    let rotations = PoseDetectionMath.cropRotations(for: person)
    let regions = PoseDetectionMath.faceGuidedRegions(face: face, personBounds: person)

    #expect(rotations == [.none, .clockwise, .counterClockwise])
    #expect(regions.count == 3)
    #expect(regions.allSatisfy { $0.width > $0.height })
    #expect(regions.contains { $0.contains(x: face.x + face.width / 2, y: face.y + face.height / 2) })
}

private func makePoseJoints(centerX: Double, centerY: Double, confidence: Double) -> [PoseJoint] {
    let definitions: [(PoseJointName, Double, Double)] = [
        (.nose, 0, -0.30),
        (.neck, 0, -0.20),
        (.leftShoulder, -0.08, -0.16),
        (.rightShoulder, 0.08, -0.16),
        (.root, 0, 0.05),
        (.leftHip, -0.06, 0.10),
        (.rightHip, 0.06, 0.10),
        (.leftKnee, -0.06, 0.28),
        (.rightKnee, 0.06, 0.28)
    ]
    return definitions.map { name, dx, dy in
        PoseJoint(name: name, x: centerX + dx, y: centerY + dy, confidence: confidence)
    }
}
