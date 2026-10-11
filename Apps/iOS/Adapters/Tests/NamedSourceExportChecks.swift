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
        // Scenario 4: a real flat-file index reconstructs the selected original
        // relative layout and independently known SHA-256, including AR poses.
        let segmentID=UUID(), frameID=UUID(), captureID=UUID()
        let segment=scan.appendingPathComponent("segments/"+segmentID.uuidString,isDirectory:true)
        try manager.createDirectory(at:segment,withIntermediateDirectories:true)
        let movie=segment.appendingPathComponent("video.mov"), poses=segment.appendingPathComponent("video.json")
        try Data("abc".utf8).write(to:movie)
        try Data("{\"frameID\":\"\(frameID.uuidString)\",\"poses\":[1,2,3]}".utf8).write(to:poses)
        let manifest=scan.appendingPathComponent("manifest.json")
        let relativeMovie="segments/\(segmentID.uuidString)/video.mov",relativePoses="segments/\(segmentID.uuidString)/video.json"
        let header:[String:Any] = ["schemaVersion":1,"id":captureID.uuidString,"projectID":projectID.uuidString,
            "status":"ready","createdAt":"2026-10-09T00:00:00Z",
            "segments":[["id":segmentID.uuidString,"frameID":frameID.uuidString,"startedAt":"2026-10-10T23:59:59Z"]],
            "completedAssets":[relativeMovie,relativePoses]]
        try JSONSerialization.data(withJSONObject:header).write(to:manifest)
        let result=try await actor.prepareResult(sources:[movie,poses,manifest],captureRoot:captures,
            projectName:"Северное кладбище",projectID:projectID,sourceID:captureID,capturedAt:nil,manifestURL:manifest)
        let indexObject=try JSONSerialization.jsonObject(with:Data(contentsOf:result.indexURL)) as! [String:Any]
        let indexFiles=indexObject["files"] as! [[String:Any]], indexMovie=indexFiles[0]
        try check(result.files.count==3 && result.manifestAliasURL==result.files.last,"Input order and manifest alias retained")
        try check(result.indexURL.deletingLastPathComponent()==exports,"Index outside capture archive tree")
        try check(indexFiles.map {$0["aliasFileName"] as! String}==result.files.map(\.lastPathComponent),"Index maps exact shared filenames")
        try check(indexMovie["originalCaptureRelativePath"] as? String==relativeMovie,"Original manifest-relative movie path reconstructable")
        try check(indexMovie["originalRelativePath"] as? String=="scan/"+relativeMovie,"Full Captures-root-relative path retained")
        try check(indexMovie["sha256"] as? String=="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad","Independent known SHA256 of exact shared abc bytes")
        try check(indexMovie["byteCount"] as? Int==3,"Exact byte count retained")
        try check((indexMovie["segmentID"] as? String)?.lowercased()==segmentID.uuidString.lowercased()
                  && (indexMovie["frameID"] as? String)?.lowercased()==frameID.uuidString.lowercased(),"AR segment/frame identity retained")
        try check(indexMovie["capturedAt"] as? Double==captureDate.timeIntervalSince1970*1000,"Original segment start is capture time")
        try check((indexObject["exportedAt"] as? Double ?? 0)>captureDate.timeIntervalSince1970*1000,"Preparation time distinct from source time")
        try check(indexFiles[1]["originalCaptureRelativePath"] as? String==relativePoses,"Pose sidecar relationship retained")
        let unknownResult=try await actor.prepareResult(sources:[video],captureRoot:captures,
            projectName:"A",projectID:projectID,sourceID:sourceID,capturedAt:nil)
        let unknownObject=try JSONSerialization.jsonObject(with:Data(contentsOf:unknownResult.indexURL)) as! [String:Any]
        let unknownFile=(unknownObject["files"] as! [[String:Any]])[0]
        try check(unknownFile["capturedAt"]==nil && unknownFile["frameID"]==nil,"Unknown capture clock/frame are not fabricated")
        try check(unknownResult.files[0].lastPathComponent.contains("capture-unknown_export-"),"Unknown source naming agrees with index")
        let beforeBadIndex=Set(try manager.contentsOfDirectory(atPath:exports.path))
        var wrongScope=false
        do { _=try await actor.prepareResult(sources:[movie,manifest],captureRoot:captures,projectName:"A",
            projectID:UUID(),sourceID:captureID,capturedAt:nil,manifestURL:manifest) }
        catch { wrongScope=true }
        try check(wrongScope,"Manifest from another project cannot authorize a share index")
        try check(Set(try manager.contentsOfDirectory(atPath:exports.path))==beforeBadIndex,"Invalid index leaves previous exports untouched")
        try check(try Data(contentsOf:movie)==Data("abc".utf8),"Index creation never changes original movie")
        print("Named source export: 4 filesystem scenarios, \(checks) checks passed")
    }
}
