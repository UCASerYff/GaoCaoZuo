import Foundation
import Darwin

@main enum CloudTransportTestMain {
    @MainActor static func main() async {
        setbuf(stdout,nil)
        do {
            GaoLocale.shared.setLanguage(.zhHans)
            try runInputCloudLocalConsentTests()
            guard CommandLine.arguments.count==2 else {throw DataFailure.message("Explicit cloud test parent required")}
            try await runInputCloudTransportTests(cloudParent:URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true))
        }catch {FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8));exit(1)}
    }
}
