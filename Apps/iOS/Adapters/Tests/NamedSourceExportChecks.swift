import Foundation

private struct SourceExportCheckError: Error { let message: String }

@main
private enum NamedSourceExportChecks {
    static func main() async throws {
        let manager=FileManager.default
        let workspace=manager.temporaryDirectory.appendingPathComponent("terraview-source-export-"+UUID().uuidString,isDirectory:true)
        try manager.createDirectory(at:workspace,withIntermediateDirectories:true)
        defer { try? manager.removeItem(at:workspace) }
        var checks=0
        func check(_ condition: @autoclosure () throws -> Bool,_ message:String) throws {
            guard try condition() else { throw SourceExportCheckError(message:message) };checks+=1
        }
        let projectID=UUID(), sourceID=UUID(), actor=NamedSourceExport()
        let captures=workspace.appendingPathComponent("Captures",isDirectory:true)
        let scan=captures.appendingPathComponent("scan",isDirectory:true)
        try manager.createDirectory(at:scan,withIntermediateDirectories:true)
        let video=scan.appendingPathComponent("cameraSource.mov"), metadata=scan.appendingPathComponent("metadata.json")
        let videoData=Data((0..<4096).map { UInt8($0%251) }), metadataData=Data("{\"capture\":\"original\"}".utf8)
        try videoData.write(to:video);try metadataData.write(to:metadata)
        let sourceAttributes=try manager.attributesOfItem(atPath:video.path)
        let exports=workspace.appendingPathComponent("Exports",isDirectory:true)
        try manager.createDirectory(at:exports,withIntermediateDirectories:false)
        let old=exports.appendingPathComponent("old-export.mov"), oldData=Data("retained old export".utf8)
        try oldData.write(to:old)
        let captureDate=ISO8601DateFormatter().date(from:"2026-10-10T23:59:59Z")!
        // Scenario 1: names + hardlink identities + original bytes + older exports.
        let first=try await actor.prepare(sources:[video,metadata],captureRoot:captures,projectName:"Северное кладбище",
            projectID:projectID,sourceID:sourceID,capturedAt:captureDate)
        try check(first.count==2,"All finalized files prepared")
        try check(first.allSatisfy { $0.deletingLastPathComponent()==exports },"Exports are outside Captures")
        try check(first.allSatisfy { $0.lastPathComponent.contains("capture-2026-10-10_23-59-59Z_export-") },"True capture time separate from export")
        try check(first.allSatisfy { $0.lastPathComponent.contains(sourceID.uuidString.lowercased()) },"Source identity retained")
        let exportedVideo=first.first { $0.pathExtension=="mov" }!
        try check(try Data(contentsOf:exportedVideo)==videoData,"Shared video bytes unchanged")
        try check(try Data(contentsOf:video)==videoData,"Original video remains unchanged")
        try check(try Data(contentsOf:metadata)==metadataData,"Original metadata remains unchanged")
        try check(try Data(contentsOf:old)==oldData,"Older exports never overwritten")
        let aliasAttributes=try manager.attributesOfItem(atPath:exportedVideo.path)
        try check(aliasAttributes[.systemFileNumber] as? NSNumber == sourceAttributes[.systemFileNumber] as? NSNumber,"Same-container hardlink avoids duplicate bytes")
        let after=try manager.attributesOfItem(atPath:video.path)
        try check(after[.modificationDate] as? Date == sourceAttributes[.modificationDate] as? Date,"Original modification date unchanged")
        let second=try await actor.prepare(sources:[video,metadata],captureRoot:captures,projectName:"Северное кладбище",
            projectID:projectID,sourceID:sourceID,capturedAt:captureDate)
        try check(Set(first).isDisjoint(with:second),"Repeated same-second sharing creates unique immutable names")
        try manager.removeItem(at:exportedVideo)
        try check(try Data(contentsOf:video)==videoData,"Unlinking alias cannot remove original")
        // Scenario 2: unknown time + deduplication, no false capture date.
        let unknown=try await actor.prepare(sources:[video,video],captureRoot:captures,projectName:"Проект",
            projectID:projectID,sourceID:sourceID,capturedAt:nil)
        try check(unknown.count==1,"Repeated path prepared once")
        try check(unknown[0].lastPathComponent.contains("capture-unknown_export-"),"Unknown capture time stays unknown")
        try check(try Data(contentsOf:unknown[0])==videoData,"Unknown-time export keeps original bytes")
        // Scenario 3: paths/symlinks/cancellation reject without altering old files.
        let beforeNames=Set(try manager.contentsOfDirectory(atPath:exports.path))
        let outside=workspace.appendingPathComponent("outside.mov");try Data("outside".utf8).write(to:outside)
        let link=scan.appendingPathComponent("linked.mov");try manager.createSymbolicLink(at:link,withDestinationURL:video)
        let folderLink=captures.appendingPathComponent("linked-folder",isDirectory:true)
        try manager.createSymbolicLink(at:folderLink,withDestinationURL:scan)
        let unsafe=[outside,link,folderLink.appendingPathComponent("cameraSource.mov"),scan,
                    URL(fileURLWithPath:captures.path+"/scan/../scan/cameraSource.mov"),URL(string:"https://example.org/source.mov")!]
        for file in unsafe {
            var rejected=false
            do { _=try await actor.prepare(sources:[video,file],captureRoot:captures,projectName:"A",projectID:projectID,sourceID:sourceID,capturedAt:nil) }
            catch { rejected=true }
            try check(rejected,"Unsafe source must reject: \(file.path)")
        }
        try check(Set(try manager.contentsOfDirectory(atPath:exports.path))==beforeNames,"Invalid batch cannot publish partial aliases")
        try check(try Data(contentsOf:old)==oldData,"Invalid batch preserves previous export")
        let cancelled=Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await actor.prepare(sources:[video],captureRoot:captures,projectName:"A",projectID:projectID,sourceID:sourceID,capturedAt:nil)
        }
        var cancelledProperly=false
        do { _=try await cancelled.value } catch is CancellationError { cancelledProperly=true }
        try check(cancelledProperly,"Cancelled preparation stops before aliases")
        try check(Set(try manager.contentsOfDirectory(atPath:exports.path))==beforeNames,"Cancellation cannot delete existing exports")
        let redirected=workspace.appendingPathComponent("redirected",isDirectory:true)
        let redirectedCaptures=redirected.appendingPathComponent("Captures",isDirectory:true)
        try manager.createDirectory(at:redirectedCaptures,withIntermediateDirectories:true)
        let redirectedFile=redirectedCaptures.appendingPathComponent("source.mov");try videoData.write(to:redirectedFile)
        try manager.createSymbolicLink(at:redirected.appendingPathComponent("Exports",isDirectory:true),withDestinationURL:exports)
        var destinationRejected=false
        do { _=try await actor.prepare(sources:[redirectedFile],captureRoot:redirectedCaptures,projectName:"A",projectID:projectID,sourceID:sourceID,capturedAt:nil) }
        catch { destinationRejected=true }
        try check(destinationRejected,"Redirected Exports directory rejects")
        try check(Set(try manager.contentsOfDirectory(atPath:exports.path))==beforeNames,"Redirect cannot modify another export directory")
        print("Named source export: 3 filesystem scenarios, \(checks) checks passed")
    }
}
