import Foundation
import Testing
@testable import NextTermCore

@Suite struct ServedURLTests {
    @Test func devServersBanners() {
        #expect(ServedURL.find(in: "  ➜  Local:   http://localhost:5173/")?.absoluteString == "http://localhost:5173/")
        #expect(ServedURL.find(in: "- 🚀 API: http://127.0.0.1:2024")?.absoluteString == "http://127.0.0.1:2024")
        #expect(ServedURL.find(in: "INFO:     Uvicorn running on http://0.0.0.0:8000 (Press CTRL+C to quit)")?.absoluteString == "http://localhost:8000")
        #expect(ServedURL.find(in: "ready on http://[::1]:3000.")?.absoluteString == "http://[::1]:3000")
        #expect(ServedURL.find(in: "Studio UI: https://localhost:8443/studio/?baseUrl=x,")?.absoluteString == "https://localhost:8443/studio/?baseUrl=x")
    }

    @Test func onlyLoopbackAddressesWithAPort() {
        #expect(ServedURL.find(in: "Network: http://192.168.1.4:5173/") == nil)
        #expect(ServedURL.find(in: "see https://example.com:443/docs") == nil)
        #expect(ServedURL.find(in: "http://localhost/ without a port") == nil)
        #expect(ServedURL.find(in: "http://localhost:99999") == nil)
        #expect(ServedURL.find(in: "nothing here") == nil)
    }

    @Test func theTitleSuffixIsThePort() {
        #expect(ServedURL.suffix(URL(string: "http://localhost:5173/")!) == " · :5173")
    }
}
