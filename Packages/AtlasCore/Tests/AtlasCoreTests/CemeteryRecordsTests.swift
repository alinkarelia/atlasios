import Foundation
import Testing
import CSQLite
@testable import AtlasCore

private func surveyPoint(project: AtlasProject, label: String = "Наблюдение") -> AtlasFeature {
    AtlasFeature(projectID: project.id, label: label, category: .grave,
                 geometry: .metricPoint(frameID: project.coordinateReference.frameID!, point: .init(x: 3, y: 4)),
                 attributes: ["survey.status": "candidate", "positionalUncertaintyMeters": "40", "originalField": "не удалять"])
}

@Test func burialCardPreservesPartialDatesMultiplePersonsPhotosAndOriginalProvenance() throws {
    let project = AtlasProject(name: "Кладбище", kind: .cemetery, coordinateReference: .localMeters(frameID: UUID()))
    let original = surveyPoint(project: project)
    let first = BurialPerson(fullName: "Иван «Петров»", birthText: "18??", deathText: "предположительно 1930", notes: "Надпись повреждена")
    let second = BurialPerson(fullName: "неразборчиво", birthText: "", deathText: "194?", notes: "Проверить архив")
    let photos = [UUID(), UUID()]
    let metadata = BurialMetadata(cemeteryID: UUID(), people: [first, second], visibleSigns: [.cross, .mound],
                                  condition: "Частично разрушено", inscriptionDraft: "OCR — требуется проверка", photoIDs: photos, identityStatus: .partial)
    let edited = try metadata.applying(to: original)
    #expect(try BurialMetadata(attributes: edited.attributes) == metadata)
    #expect(edited.id == original.id && edited.revision == original.revision && edited.geometry == original.geometry)
    #expect(edited.attributes["originalField"] == "не удалять")
    #expect(edited.attributes["positionalUncertaintyMeters"] == "40")
    #expect(edited.attributes["survey.status"] == "candidate")
}

@Test func confirmedBurialCanHaveUnknownIdentityWithoutAnyPerson() throws {
    let project = AtlasProject(name: "Кладбище", kind: .cemetery, coordinateReference: .localMeters(frameID: UUID()))
    let feature = try BurialMetadata(visibleSigns: [.noVisibleMarker]).applying(to: surveyPoint(project: project))
    let confirmed = SurveyFeatureLifecycle.confirm(feature, at: Date(timeIntervalSince1970: 1_800_000_000), basis: "Запись в архиве")
    let metadata = try BurialMetadata(attributes: confirmed.attributes)
    #expect(metadata.people.isEmpty && metadata.identityStatus == .unknown)
    #expect(SurveyFeatureLifecycle.status(of: confirmed) == .confirmed)
    #expect(confirmed.attributes["grave.confirmationBasis"] == "Запись в архиве")
    #expect(confirmed.attributes["grave.confirmedBy"] == nil)
    #expect(confirmed.attributes["positionalUncertaintyMeters"] == "40")
}

@Test func malformedCardNeverSilentlyBecomesEmptyAndParentAliasMigratesExplicitly() throws {
    let cemeteryID = UUID()
    let decoded = try BurialMetadata(attributes: ["parentCemeteryID": cemeteryID.uuidString, "unrelated": "original"])
    #expect(decoded.cemeteryID == cemeteryID)
    #expect(throws: BurialMetadataError.conflictingCemeteryIDs) {
        _ = try BurialMetadata(attributes: ["cemeteryID": UUID().uuidString, "parentCemeteryID": cemeteryID.uuidString])
    }
    #expect(throws: BurialMetadataError.malformedAttribute("grave.persons")) {
        _ = try BurialMetadata(attributes: ["grave.persons": "[{broken]"])
    }
    #expect(throws: BurialMetadataError.malformedAttribute("grave.identityStatus")) {
        _ = try BurialMetadata(attributes: ["grave.identityStatus": "guessed"])
    }
    var feature = surveyPoint(project: .init(name: "C", kind: .cemetery, coordinateReference: .localMeters(frameID: UUID())))
    feature.attributes["parentCemeteryID"] = cemeteryID.uuidString
    let migrated = try decoded.applying(to: feature)
    #expect(migrated.attributes["cemeteryID"] == cemeteryID.uuidString)
    #expect(migrated.attributes["parentCemeteryID"] == nil)
}

@Test func boundedCardsRejectDuplicateReferencesAndOversizedUTF16BeforeSaving() throws {
    let person = BurialPerson(fullName: "Человек")
    #expect(throws: BurialMetadataError.duplicatePersonID) { try BurialMetadata(people: [person, person]).validate() }
    let photo = UUID()
    #expect(throws: BurialMetadataError.duplicatePhotoID) { try BurialMetadata(photoIDs: [photo, photo]).validate() }
    #expect(throws: BurialMetadataError.oversizedAttribute("grave.inscriptionDraft")) {
        try BurialMetadata(inscriptionDraft: String(repeating: "😀", count: 1025)).validate()
    }
}

@Test func reversibleReviewKeepsIdentityGeometrySourceUncertaintyAndConfirmationHistory() async throws {
    let store = try AtlasStore(path: ":memory:")
    let project = try await store.saveProject(.init(name: "Кладбище", kind: .cemetery, coordinateReference: .localMeters(frameID: UUID())))
    let original = try await store.saveFeature(surveyPoint(project: project))
    let confirmed = try await store.saveFeature(SurveyFeatureLifecycle.confirm(original, basis: "Осмотр оператора"))
    let rejected = try await store.saveFeature(SurveyFeatureLifecycle.reject(confirmed))
    #expect(!SurveyFeatureLifecycle.isActive(rejected))
    let restored = try await store.saveFeature(SurveyFeatureLifecycle.restore(rejected))
    #expect(SurveyFeatureLifecycle.status(of: restored) == .confirmed && SurveyFeatureLifecycle.isActive(restored))
    let removed = try await store.saveFeature(SurveyFeatureLifecycle.remove(restored))
    let returned = try await store.saveFeature(SurveyFeatureLifecycle.restore(removed))
    try await store.acknowledgeOutbox(eventIDs: try await store.pendingOutbox().map(\.id))
    let history = try await store.featureHistory(featureID: original.id, projectID: project.id)
    #expect(history.map(\.revision) == [1, 2, 3, 4, 5, 6])
    #expect(history.map(\.id).allSatisfy { $0 == original.id })
    #expect(history.map(\.geometry).allSatisfy { $0 == original.geometry })
    #expect(history.allSatisfy { $0.attributes["positionalUncertaintyMeters"] == "40" })
    #expect(SurveyFeatureLifecycle.isSoftRemoved(history[4]))
    #expect(!SurveyFeatureLifecycle.isSoftRemoved(returned))
    #expect(history[1].attributes["grave.confirmationBasis"] == "Осмотр оператора")
    #expect(try await store.pendingOutbox().isEmpty)
}

@Test func actualPointsAndOpenLinesSurviveDiskReopenWithScopeAndRevisionProtection() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("terraview-survey-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("project.sqlite").path
    let store = try AtlasStore(path: path)
    let project = try await store.saveProject(.init(name: "Схема", kind: .cemetery, coordinateReference: .localMeters(frameID: UUID())))
    let point = try await store.saveFeature(surveyPoint(project: project))
    let line = try await store.saveFeature(.init(projectID: project.id, label: "Ограда", category: .fence,
        geometry: .metricPolyline(.init(frameID: project.coordinateReference.frameID!, vertices: [.init(x: 0, y: 0), .init(x: 3, y: 4), .init(x: 6, y: 4)]))))
    let reopened = try AtlasStore(path: path)
    let snapshot = try await reopened.snapshot(projectID: project.id)
    #expect(Set(snapshot.features) == Set([point, line]))
    #expect(try await reopened.featureHistory(featureID: point.id, projectID: project.id) == [point])
    let other = try await reopened.saveProject(.init(name: "Другой", kind: .cemetery, coordinateReference: project.coordinateReference))
    #expect(try await reopened.featureHistory(featureID: point.id, projectID: other.id).isEmpty)
    var stale = point; stale.notes = "после открытия"
    _ = try await reopened.saveFeature(stale)
    await #expect(throws: AtlasStoreError.revisionConflict(entityID: point.id, expected: 1, actual: 2)) {
        try await reopened.saveFeature(point)
    }
}

@Test func geometryBoundsOpenLineLengthAndFrameRulesAreExplicit() throws {
    let frame = UUID()
    let line = MetricPolyline(frameID: frame, vertices: [.init(x: 0, y: 0), .init(x: 3, y: 4), .init(x: 6, y: 4)])
    #expect(try PolygonGeometry.length(of: line) == 8)
    #expect(throws: GeometryError.coordinateFrameMismatch) { try PolygonGeometry.validate(.metricPolyline(line), in: .localMeters(frameID: UUID())) }
    #expect(throws: GeometryError.tooFewLineVertices) { try PolygonGeometry.validate(MetricPolyline(frameID: frame, vertices: [.init(x: 0, y: 0)])) }
    #expect(throws: GeometryError.tooManyVertices) {
        try PolygonGeometry.validate(MetricPolyline(frameID: frame, vertices: (0...2048).map { .init(x: Double($0), y: 0) }))
    }
    // A road may intentionally cross itself; it still has no enclosed area.
    try PolygonGeometry.validate(MetricPolyline(frameID: frame, vertices: [.init(x: 0, y: 0), .init(x: 4, y: 4), .init(x: 0, y: 4), .init(x: 4, y: 0)]))
}

@Test func historyCursorReturnsEveryRevisionOnceAfterMoreThanOneHundredEdits() async throws {
    let store = try AtlasStore(path: ":memory:")
    let project = try await store.saveProject(.init(name: "История", kind: .cemetery, coordinateReference: .localMeters(frameID: UUID())))
    var feature = surveyPoint(project: project)
    for revision in 1...205 {
        feature.notes = "Осмотр \(revision)"
        feature = try await store.saveFeature(feature)
    }
    try await store.acknowledgeOutbox(eventIDs: try await store.pendingOutbox().map(\.id))
    var cursor: Int64?, history: [AtlasFeature] = []
    while true {
        let page = try await store.featureHistory(featureID: feature.id, projectID: project.id, beforeRevision: cursor)
        if page.isEmpty { break }
        history.insert(contentsOf: page, at: 0)
        cursor = page.first!.revision
    }
    #expect(history.map(\.revision) == Array(Int64(1)...205))
    #expect(history.first?.notes == "Осмотр 1" && history.last?.notes == "Осмотр 205")
    #expect(Set(history.map(\.revision)).count == 205)
}

@Test func complexBurialCardsPreserveRoofUnknownsHistoricalUncertaintyAndLinkedPeople() throws {
    let project = AtlasProject(name: "Кладбище", kind: .cemetery, coordinateReference: .localMeters(frameID: UUID()))
    let complexID = UUID()
    let metadata = BurialMetadata(people: [BurialPerson(fullName: "Надпись утрачена")], identityStatus: .unknown,
                                  burialType: .mausoleum, hasRoof: true, warContext: "Предположительно 1941–1945; проверить",
                                  warContextSource: "Слова родственника, документ отсутствует", complexID: complexID)
    let feature = try metadata.applying(to: surveyPoint(project: project))
    let decoded = try BurialMetadata(attributes: feature.attributes)
    #expect(decoded == metadata)
    #expect(decoded.hasRoof == true && decoded.identityStatus == .unknown)
    #expect(feature.attributes["grave.warContext"] == "Предположительно 1941–1945; проверить")
    #expect(feature.attributes["grave.warContextSource"] == "Слова родственника, документ отсутствует")
    let second = try BurialMetadata(burialType: .family, hasRoof: nil, complexID: complexID).applying(to: surveyPoint(project: project))
    #expect(second.id != feature.id && second.attributes["grave.complexID"] == feature.attributes["grave.complexID"])
    #expect(second.attributes["grave.hasRoof"] == nil)
    let explicitNo = try BurialMetadata(hasRoof: false).applying(to: surveyPoint(project: project))
    #expect(try BurialMetadata(attributes: explicitNo.attributes).hasRoof == false)
}

@Test func versionTwoMigrationSeedsOnlyRetainedBaselineAndNeverInventsLostEarlierHistory() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("terraview-migration-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("project.sqlite").path
    let current = try AtlasStore(path: path)
    let project = try await current.saveProject(.init(name: "Ранний проект", kind: .cemetery, coordinateReference: .localMeters(frameID: UUID())))
    var feature = surveyPoint(project: project)
    for _ in 1...7 { feature = try await current.saveFeature(feature) }
    // Reconstruct the earlier app's genuine schema: its latest feature was
    // persisted, while acknowledged older revisions were not retained locally.
    var handle: OpaquePointer?
    #expect(sqlite3_open(path, &handle) == SQLITE_OK)
    let database = try #require(handle)
    defer { sqlite3_close(database) }
    #expect(sqlite3_exec(database, "DROP TABLE cemetery_feature_links; DROP TABLE feature_revisions; PRAGMA user_version = 2", nil, nil, nil) == SQLITE_OK)
    let migrated = try AtlasStore(path: path)
    #expect(try await migrated.featureHistory(featureID: feature.id, projectID: project.id) == [feature])
    var changed = feature; changed.notes = "Первое изменение после обновления"
    let saved = try await migrated.saveFeature(changed)
    #expect(try await migrated.featureHistory(featureID: feature.id, projectID: project.id).map(\.revision) == [7, 8])
    #expect(saved.id == feature.id && saved.geometry == feature.geometry)
}

@Test func legacyReviewedGraveDoesNotBecomeConfirmedWithoutAnExplicitBurialDecision() throws {
    let data = Data("""
        {"id":"00000000-0000-4000-8000-000000000001","projectID":"00000000-0000-4000-8000-000000000002", "label":"Старая карточка", "category":"grave", "geometry":{"metricPolygon":{"_0":{"frameID":"00000000-0000-4000-8000-000000000003","vertices":[{"x":0,"y":0},{"x":2,"y":0},{"x":2,"y":3}],"holes":[]}}}, "attributes":{}, "notes":"Проверена только геометрия", "reviewStatus":"reviewed", "revision":8}
        """.utf8)
    let legacy = try AtlasJSON.decode(AtlasFeature.self, from:data)
    #expect(SurveyFeatureLifecycle.status(of:legacy) == .candidate)
    #expect(try BurialMetadata(attributes:legacy.attributes).identityStatus == .unknown)
    var explicit = legacy; explicit.attributes["survey.status"] = "confirmed"
    #expect(SurveyFeatureLifecycle.status(of:explicit) == .confirmed)
    #expect(explicit.id == legacy.id && explicit.geometry == legacy.geometry && explicit.revision == 8)
}

@Test func canonicalAndLegacyParentLinksCannotCrossProjectOrDisagree() async throws {
    let store = try AtlasStore(path:":memory:"), frame = UUID()
    let first = try await store.saveProject(.init(name:"A",kind:.cemetery,coordinateReference:.localMeters(frameID:frame)))
    let second = try await store.saveProject(.init(name:"B",kind:.cemetery,coordinateReference:first.coordinateReference))
    var parent = surveyPoint(project:second); parent.category = .cemetery
    parent = try await store.saveFeature(parent)
    for key in ["cemeteryID","parentCemeteryID"] {
        var child = surveyPoint(project:first); child.attributes[key] = parent.id.uuidString.lowercased()
        await #expect(throws:AtlasStoreError.self) { try await store.saveFeature(child) }
    }
    var ambiguous = surveyPoint(project:first)
    ambiguous.attributes["cemeteryID"] = UUID().uuidString; ambiguous.attributes["parentCemeteryID"] = UUID().uuidString
    await #expect(throws:AtlasStoreError.self) { try await store.saveFeature(ambiguous) }
    #expect(try await store.features(projectID:first.id).isEmpty)
}

@Test func unresolvedCemeteryLinkCanResolveOnlyToCemeteryInItsOriginalProject() async throws {
    let store = try AtlasStore(path:":memory:"), frame = UUID(), parentID = UUID()
    let first = try await store.saveProject(.init(name:"A",kind:.cemetery,coordinateReference:.localMeters(frameID:frame)))
    let second = try await store.saveProject(.init(name:"B",kind:.cemetery,coordinateReference:first.coordinateReference))
    var child = surveyPoint(project:first); child.attributes["parentCemeteryID"] = parentID.uuidString
    child = try await store.saveFeature(child)
    var parent = surveyPoint(project:second); parent.id = parentID; parent.category = .cemetery
    await #expect(throws:AtlasStoreError.self) { try await store.saveFeature(parent) }
    parent.projectID = first.id; parent.category = .other
    await #expect(throws:AtlasStoreError.self) { try await store.saveFeature(parent) }
    parent.category = .cemetery
    let resolved = try await store.saveFeature(parent)
    #expect(resolved.id == parentID)
    #expect(try await store.features(projectID:first.id).contains(child))
    #expect(try await store.features(projectID:second.id).isEmpty)
}

@Test func cemeteryWithChildrenCannotChangeTypeUntilLinksAreExplicitlyRemoved() async throws {
    let store = try AtlasStore(path:":memory:")
    let project = try await store.saveProject(.init(name:"A",kind:.cemetery,coordinateReference:.localMeters(frameID:UUID())))
    var parent = surveyPoint(project:project); parent.category = .cemetery
    parent = try await store.saveFeature(parent)
    var child = surveyPoint(project:project); child.attributes["cemeteryID"] = parent.id.uuidString
    child = try await store.saveFeature(child)
    var changed = parent; changed.category = .other
    await #expect(throws:AtlasStoreError.self) { try await store.saveFeature(changed) }
    #expect(try await store.featureHistory(featureID:parent.id,projectID:project.id) == [parent])
    // Unlinking is a reversible audited edit, rather than deleting the child.
    child.attributes.removeValue(forKey:"cemeteryID")
    child = try await store.saveFeature(child)
    let saved = try await store.saveFeature(changed)
    #expect(saved.category == .other && saved.revision == 2)
    #expect(try await store.featureHistory(featureID:child.id,projectID:project.id).count == 2)
}

@Test func schemaThreeMigrationIndexesEveryLegacyReferenceWithoutRewritingCardsOrHistory() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("terraview-parent-migration-" + UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:directory) }
    let path = directory.appendingPathComponent("project.sqlite").path, frame = UUID(), parentID = UUID()
    let current = try AtlasStore(path:path)
    let first = try await current.saveProject(.init(name:"A",kind:.cemetery,coordinateReference:.localMeters(frameID:frame)))
    let second = try await current.saveProject(.init(name:"B",kind:.cemetery,coordinateReference:first.coordinateReference))
    var original: [AtlasFeature] = []
    // More than two migration pages, with genuine unresolved legacy links.
    for index in 0..<70 {
        var child = surveyPoint(project:first,label:"Карточка \(index)")
        child.attributes["parentCemeteryID"] = parentID.uuidString.lowercased()
        original.append(try await current.saveFeature(child))
    }
    var handle: OpaquePointer?
    #expect(sqlite3_open(path,&handle) == SQLITE_OK)
    let database = try #require(handle); defer { sqlite3_close(database) }
    #expect(sqlite3_exec(database,"DROP TABLE cemetery_feature_links; PRAGMA user_version = 3",nil,nil,nil) == SQLITE_OK)
    let migrated = try AtlasStore(path:path)
    #expect(Set(try await migrated.features(projectID:first.id)) == Set(original))
    #expect(try await migrated.featureHistory(featureID:original[0].id,projectID:first.id) == [original[0]])
    var foreign = surveyPoint(project:second); foreign.id = parentID; foreign.category = .cemetery
    await #expect(throws:AtlasStoreError.self) { try await migrated.saveFeature(foreign) }
    foreign.projectID = first.id
    let parent = try await migrated.saveFeature(foreign)
    #expect(parent.id == parentID && parent.category == .cemetery)
    var wrongType = parent; wrongType.category = .other
    await #expect(throws:AtlasStoreError.self) { try await migrated.saveFeature(wrongType) }
}
